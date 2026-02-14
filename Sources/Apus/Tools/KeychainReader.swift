import Foundation
import Security

/// MCP tool that lists Keychain items (metadata only, values are redacted).
final class KeychainReader: MCPTool {
    var toolName: String { "get_keychain_items" }
    var toolDescription: String {
        "List keychain items for the app. Shows metadata only — actual secret values are redacted for security."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "service": [
                    "type": "string",
                    "description": "Filter by service name"
                ],
                "item_class": [
                    "type": "string",
                    "description": "Keychain item class (default: generic_password)",
                    "enum": ["generic_password", "internet_password"]
                ]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let service = arguments["service"] as? String
        let itemClass = arguments["item_class"] as? String ?? "generic_password"

        let secClass: CFString
        switch itemClass {
        case "internet_password":
            secClass = kSecClassInternetPassword
        default:
            secClass = kSecClassGenericPassword
        }

        var query: [String: Any] = [
            kSecClass as String: secClass,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        if let service = service {
            query[kSecAttrService as String] = service
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                return .text("No keychain items found.")
            }
            return .error("Keychain query failed with status: \(status)")
        }

        let dateFormatter = ISO8601DateFormatter()

        let formatted = items.enumerated().map { index, item in
            var parts: [String] = ["[\(index)]"]

            if let svc = item[kSecAttrService as String] as? String {
                parts.append("service: \(svc)")
            }
            if let account = item[kSecAttrAccount as String] as? String {
                parts.append("account: \(account)")
            }
            if let label = item[kSecAttrLabel as String] as? String {
                parts.append("label: \(label)")
            }
            if let created = item[kSecAttrCreationDate as String] as? Date {
                parts.append("created: \(dateFormatter.string(from: created))")
            }
            if let modified = item[kSecAttrModificationDate as String] as? Date {
                parts.append("modified: \(dateFormatter.string(from: modified))")
            }
            parts.append("(value redacted)")

            return parts.joined(separator: " | ")
        }.joined(separator: "\n")

        return .text("Keychain Items (\(items.count) found):\n\n\(formatted)")
    }
}
