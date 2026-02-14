import Foundation

/// MCP tool that reads UserDefaults key-value pairs.
final class UserDefaultsReader: MCPTool {
    var toolName: String { "get_user_defaults" }
    var toolDescription: String {
        "Read all UserDefaults key-value pairs for the app. Optionally filter by key prefix."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "prefix": [
                    "type": "string",
                    "description": "Optional prefix to filter keys (e.g., 'com.myapp')"
                ]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let prefix = arguments["prefix"] as? String
        let defaults = UserDefaults.standard.dictionaryRepresentation()

        var filtered = defaults
        if let prefix = prefix {
            filtered = defaults.filter { $0.key.hasPrefix(prefix) }
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
        return String(describing: value)
    }
}
