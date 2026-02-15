import Foundation

/// MCP tool that exposes app metadata: Info.plist, bundle info, build configuration,
/// loaded frameworks, and environment details.
final class AppInfoInspector: MCPTool {
    var toolName: String { "get_app_info" }
    var toolDescription: String {
        "App identity: bundle ID, version, config. Use section param for plist/frameworks."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "section": [
                    "type": "string",
                    "enum": ["all", "full", "bundle", "plist", "frameworks", "environment"],
                    "description": "Which section to return (default: all = bundle + environment). Use 'full' for everything, or 'plist'/'frameworks' explicitly."
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let section = arguments["section"] as? String ?? "all"

        var sections: [String] = []

        if section == "all" || section == "full" || section == "bundle" {
            sections.append(bundleSection())
        }
        if section == "all" || section == "full" || section == "environment" {
            sections.append(environmentSection())
        }
        if section == "full" || section == "plist" {
            sections.append(plistSection())
        }
        if section == "full" || section == "frameworks" {
            sections.append(frameworksSection())
        }

        return .text(sections.joined(separator: "\n\n"))
    }

    // MARK: - Sections

    private func bundleSection() -> String {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "unknown"
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let name = bundle.infoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "unknown"
        let minOS = bundle.infoDictionary?["MinimumOSVersion"] as? String ?? "unknown"
        let executable = bundle.executableURL?.lastPathComponent ?? "unknown"

        return """
        App Bundle:
          Name:           \(name)
          Bundle ID:      \(bundleId)
          Version:        \(version) (\(build))
          Min OS:         \(minOS)
          Executable:     \(executable)
          Bundle Path:    \(bundle.bundlePath)
        """
    }

    private func environmentSection() -> String {
        var lines: [String] = ["Environment:"]

        // Build configuration
        #if DEBUG
        lines.append("  Configuration:  DEBUG")
        #else
        lines.append("  Configuration:  RELEASE")
        #endif

        // Architecture
        #if arch(arm64)
        lines.append("  Architecture:   arm64")
        #elseif arch(x86_64)
        lines.append("  Architecture:   x86_64 (Rosetta)")
        #else
        lines.append("  Architecture:   unknown")
        #endif

        // Platform
        #if targetEnvironment(simulator)
        lines.append("  Runtime:        Simulator")
        #else
        lines.append("  Runtime:        Device")
        #endif

        #if os(iOS)
        lines.append("  Platform:       iOS")
        #elseif os(macOS)
        lines.append("  Platform:       macOS")
        #elseif os(tvOS)
        lines.append("  Platform:       tvOS")
        #elseif os(watchOS)
        lines.append("  Platform:       watchOS")
        #endif

        // Process info
        let process = ProcessInfo.processInfo
        lines.append("  OS Version:     \(process.operatingSystemVersionString)")
        lines.append("  Process ID:     \(process.processIdentifier)")
        lines.append("  Process Name:   \(process.processName)")
        lines.append("  Processor Count: \(process.processorCount)")
        lines.append("  Active Processors: \(process.activeProcessorCount)")

        // Thermal state
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        lines.append("  Thermal State:  \(thermal)")

        // Low power mode
        lines.append("  Low Power Mode: \(process.isLowPowerModeEnabled)")

        return lines.joined(separator: "\n")
    }

    private func plistSection() -> String {
        guard let info = Bundle.main.infoDictionary else {
            return "Info.plist: unavailable"
        }

        var lines: [String] = ["Info.plist (\(info.count) entries):"]

        for key in info.keys.sorted() {
            let value = info[key]
            let valueStr = compactDescription(value)
            lines.append("  \(key): \(valueStr)")
        }

        return lines.joined(separator: "\n")
    }

    private func frameworksSection() -> String {
        let allBundles = Bundle.allFrameworks
        let appBundles = allBundles.filter { bundle in
            // Filter out Apple frameworks by bundle identifier
            if let bundleId = bundle.bundleIdentifier {
                return !bundleId.hasPrefix("com.apple")
            }
            // No bundle ID: filter by path as fallback
            let path = bundle.bundlePath
            return !path.hasPrefix("/System") && !path.hasPrefix("/usr")
        }

        var lines: [String] = ["Loaded Frameworks (\(appBundles.count) app/third-party, \(allBundles.count) total):"]

        for bundle in appBundles.sorted(by: { $0.bundlePath < $1.bundlePath }) {
            let name = bundle.bundleURL.lastPathComponent
            let id = bundle.bundleIdentifier ?? ""
            if id.isEmpty {
                lines.append("  \(name)")
            } else {
                lines.append("  \(name) (\(id))")
            }
        }

        if appBundles.isEmpty {
            lines.append("  (none — all frameworks are system)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func compactDescription(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        if let dict = value as? [String: Any] {
            return "{\(dict.count) entries}"
        }
        if let arr = value as? [Any] {
            if arr.count <= 5 {
                return "[\(arr.map { "\($0)" }.joined(separator: ", "))]"
            }
            return "[\(arr.count) items]"
        }
        return "\(value)"
    }
}
