import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// MCP tool that provides a comprehensive diagnostic summary in a single call.
/// Aggregates data from memory, logs, network, app info, and UserDefaults
/// to give the AI agent a complete picture of the app's health.
final class DiagnosticsTool: MCPTool {
    var toolName: String { "get_diagnostics" }
    var toolDescription: String {
        "Start here. Quick app health: info, memory, errors, network failures, config."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [:] as [String: Any]
        ]
    }

    private weak var logCapture: LogCapture?
    private weak var networkInterceptor: NetworkInterceptor?
    private weak var actionRunner: ActionRunner?
    private let toolRegistry: ToolRegistry

    init(
        logCapture: LogCapture,
        networkInterceptor: NetworkInterceptor?,
        actionRunner: ActionRunner,
        toolRegistry: ToolRegistry
    ) {
        self.logCapture = logCapture
        self.networkInterceptor = networkInterceptor
        self.actionRunner = actionRunner
        self.toolRegistry = toolRegistry
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        var sections: [String] = []

        sections.append(appSection())
        sections.append(memorySection())
        sections.append(await errorsSection())
        sections.append(await networkSection())
        sections.append(defaultsSection())
        sections.append(statusSection())

        return .text(sections.joined(separator: "\n\n"))
    }

    // MARK: - App Info

    private func appSection() -> String {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "unknown"
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let name = bundle.infoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundleId

        let process = ProcessInfo.processInfo

        var config = "RELEASE"
        #if DEBUG
        config = "DEBUG"
        #endif

        var platform = "unknown"
        #if targetEnvironment(simulator)
        platform = "Simulator"
        #else
        platform = "Device"
        #endif

        return "App: \(name) \(version) (\(build)) | \(bundleId) | \(platform) \(config) | PID \(process.processIdentifier)"
    }

    // MARK: - Memory

    private func memorySection() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return "Memory: unavailable"
        }

        let physical = formatBytes(UInt64(info.phys_footprint))
        let peak = formatBytes(UInt64(info.resident_size_peak))

        // Heap stats
        var heapStats = malloc_statistics_t()
        malloc_zone_statistics(nil, &heapStats)
        let heapInUse = formatBytes(UInt64(heapStats.size_in_use))

        // Available memory
        var availStr = ""
        #if os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        availStr = ", system available: \(formatBytes(UInt64(available)))"
        #endif

        // Warning if memory is high
        let physicalMB = Double(info.phys_footprint) / 1_048_576
        let warning = physicalMB > 200 ? "\n  ⚠️  Memory usage above 200MB" : ""

        return """
        Memory: \(physical) (peak: \(peak))
          Heap: \(heapInUse) (\(heapStats.blocks_in_use) blocks)\(availStr)\(warning)
        """
    }

    // MARK: - Recent Errors

    private func errorsSection() async -> String {
        guard let logCapture = logCapture else {
            return "Recent Errors: log capture unavailable"
        }

        let result = try? await logCapture.execute(arguments: [
            "tail": 5,
            "level": "error"
        ])

        guard let result = result, case .text(let text) = result.content.first else {
            return "Recent Errors: none"
        }

        if text.contains("No log entries found") {
            return "Recent Errors: none"
        }

        // Extract just the log lines (skip the header)
        let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        let recentErrors = lines.suffix(5)

        if recentErrors.isEmpty {
            return "Recent Errors: none"
        }

        let formatted = recentErrors.map { "  " + $0 }.joined(separator: "\n")
        let total = lines.count
        let showing = recentErrors.count

        return """
        Recent Errors (\(total) total, showing last \(showing)):
        \(formatted)
        """
    }

    // MARK: - Network

    private func networkSection() async -> String {
        guard let interceptor = networkInterceptor else {
            return "Network: interception not enabled (start with interceptNetwork: true)"
        }

        let result = try? await interceptor.execute(arguments: ["tail": 5])

        guard let result = result, case .text(let text) = result.content.first else {
            return "Network: no requests recorded"
        }

        if text.contains("No network requests recorded") {
            return "Network: no requests recorded"
        }

        // Parse the network history to extract summary
        let records = text.components(separatedBy: "\n---\n")
        let totalRequests = records.count

        // Count failures (status >= 400 or "Error:")
        var failures: [String] = []
        for record in records {
            let lines = record.components(separatedBy: "\n")
            let hasError = lines.contains(where: { $0.contains("Error:") })
            let statusLine = lines.first(where: { $0.contains("Status:") })

            if hasError {
                if let firstLine = lines.first(where: { $0.contains("]") }) {
                    failures.append(firstLine.trimmingCharacters(in: .whitespaces))
                }
            } else if let statusLine = statusLine {
                // Extract status code
                if let range = statusLine.range(of: "Status: ") {
                    let statusStr = String(statusLine[range.upperBound...]).prefix(3)
                    if let code = Int(statusStr), code >= 400 {
                        if let firstLine = lines.first(where: { $0.contains("]") }) {
                            failures.append(firstLine.trimmingCharacters(in: .whitespaces))
                        }
                    }
                }
            }
        }

        var section = "Network: \(totalRequests) requests recorded"
        if failures.isEmpty {
            section += ", all successful"
        } else {
            section += ", \(failures.count) failed"
            let showing = failures.suffix(3)
            for failure in showing {
                section += "\n  ❌ \(failure)"
            }
        }

        return section
    }

    // MARK: - UserDefaults

    private func defaultsSection() -> String {
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        // Filter to app-specific keys (skip Apple system keys)
        let appKeys = defaults.keys.filter { key in
            !key.hasPrefix("Apple") &&
            !key.hasPrefix("NS") &&
            !key.hasPrefix("com.apple") &&
            !key.hasPrefix("AK") &&
            !key.hasPrefix("INNext") &&
            !key.hasPrefix("PK")
        }

        return "UserDefaults: \(appKeys.count) app keys (\(defaults.count) total including system)"
    }

    // MARK: - Status

    private func statusSection() -> String {
        let toolCount = toolRegistry.toolCount
        let actionCount = actionRunner?.actionCount ?? 0

        return "Status: \(toolCount) tools active, \(actionCount) actions registered"
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
