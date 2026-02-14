import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// MCP tool that reports the app's memory usage stats.
/// Uses task_info for physical footprint and os_proc_available_memory for system availability.
/// Zero configuration — always available.
final class MemoryInspector: MCPTool {
    var toolName: String { "get_memory_stats" }
    var toolDescription: String {
        "Get the app's current memory usage: physical footprint, peak memory, available system memory, and malloc heap statistics."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "include_zones": [
                    "type": "boolean",
                    "description": "Include per-zone malloc heap breakdown (default: false)"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let includeZones = arguments["include_zones"] as? Bool ?? false
        var sections: [String] = []

        // 1. Task VM info (physical footprint, peak, resident)
        sections.append(taskMemorySection())

        // 2. Available system memory
        sections.append(availableMemorySection())

        // 3. Malloc heap stats
        sections.append(heapSection(includeZones: includeZones))

        return .text(sections.joined(separator: "\n\n"))
    }

    // MARK: - task_info (physical footprint)

    private func taskMemorySection() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return "Memory (task_info): unavailable (error \(result))"
        }

        let physical = formatBytes(UInt64(info.phys_footprint))
        let resident = formatBytes(UInt64(info.resident_size))
        let virtualSize = formatBytes(UInt64(info.virtual_size))
        let peakPhysical = formatBytes(UInt64(info.resident_size_peak))
        let compressed = formatBytes(UInt64(info.compressed))
        let internalMem = formatBytes(UInt64(info.internal))
        let externalMem = formatBytes(UInt64(info.external))

        return """
        Memory Usage:
          Physical footprint:  \(physical)
          Peak resident:       \(peakPhysical)
          Resident size:       \(resident)
          Virtual size:        \(virtualSize)
          Internal (app data): \(internalMem)
          External (shared):   \(externalMem)
          Compressed:          \(compressed)
        """
    }

    // MARK: - Available memory

    private func availableMemorySection() -> String {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let available = os_proc_available_memory()
        return "System Available Memory: \(formatBytes(UInt64(available)))"
        #else
        // os_proc_available_memory is not available on macOS.
        // Fall back to host_statistics for a rough estimate.
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "System Available Memory: unavailable"
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let available = free + inactive
        return "System Available Memory: ~\(formatBytes(available)) (free + inactive)"
        #endif
    }

    // MARK: - Malloc heap stats

    private func heapSection(includeZones: Bool) -> String {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)

        let inUse = formatBytes(UInt64(stats.size_in_use))
        let allocated = formatBytes(UInt64(stats.size_allocated))
        let maxInUse = formatBytes(UInt64(stats.max_size_in_use))

        var section = """
        Heap (all zones combined):
          In use:     \(inUse) (\(stats.blocks_in_use) blocks)
          Allocated:  \(allocated)
          Peak in use: \(maxInUse)
        """

        if includeZones {
            section += "\n\n" + perZoneBreakdown()
        }

        return section
    }

    private func perZoneBreakdown() -> String {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        let result = malloc_get_all_zones(mach_task_self_, nil, &addresses, &count)
        guard result == KERN_SUCCESS, let addresses = addresses, count > 0 else {
            return "Zone breakdown: unavailable"
        }

        var lines: [String] = ["Heap zones:"]

        for i in 0..<Int(count) {
            let zonePtr = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[i]))
            guard let zone = zonePtr else { continue }
            let name: String
            if let zoneName = malloc_get_zone_name(zone) {
                name = String(cString: zoneName)
            } else {
                name = "zone_\(i)"
            }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)

            let inUse = formatBytes(UInt64(stats.size_in_use))
            let allocated = formatBytes(UInt64(stats.size_allocated))
            lines.append("  [\(i)] \(name): \(inUse) in use / \(allocated) allocated (\(stats.blocks_in_use) blocks)")
        }

        return lines.joined(separator: "\n")
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
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
