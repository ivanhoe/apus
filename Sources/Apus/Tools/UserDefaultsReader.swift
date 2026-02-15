import Foundation

/// MCP tool that reads UserDefaults key-value pairs.
final class UserDefaultsReader: MCPTool {
    var toolName: String { "get_user_defaults" }
    var toolDescription: String {
        "App UserDefaults (system keys hidden). Use prefix or include_system=true."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "prefix": [
                    "type": "string",
                    "description": "Optional prefix to filter keys (e.g., 'com.myapp')"
                ],
                "include_system": [
                    "type": "boolean",
                    "description": "Include Apple/system keys (default: false)"
                ]
            ] as [String: Any]
        ]
    }

    private static let systemPrefixes = ["Apple", "NS", "com.apple", "AK", "PK", "AddingEmoji"]

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let prefix = arguments["prefix"] as? String
        let includeSystem = arguments["include_system"] as? Bool ?? false
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        var filtered = defaults

        // Filter by prefix if specified
        if let prefix = prefix {
            filtered = defaults.filter { $0.key.hasPrefix(prefix) }
        }

        // Filter out system keys unless explicitly requested
        if !includeSystem && prefix == nil {
            filtered = filtered.filter { entry in
                !Self.systemPrefixes.contains(where: { entry.key.hasPrefix($0) })
            }
        }

        if filtered.isEmpty {
            let msg = prefix != nil
                ? "No UserDefaults entries found with prefix '\(prefix!)'."
                : "No UserDefaults entries found."
            return .text(msg)
        }

        let formatted = filtered.keys.sorted().map { key in
            let value = filtered[key]!
            let valueStr = formatValue(value)
            let typeStr = String(describing: type(of: value))
            return "\(key) (\(typeStr)): \(valueStr)"
        }.joined(separator: "\n")

        return .text("UserDefaults (\(filtered.count) entries):\n\n\(formatted)")
    }

    private func formatValue(_ value: Any) -> String {
        if let data = value as? Data {
            return "<Data: \(data.count) bytes>"
        }
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        let str = String(describing: value)
        if str.count > 200 {
            return String(str.prefix(200)) + "... (\(str.count) chars)"
        }
        return str
    }
}
