import XCTest
import Security
@testable import Apus

final class KeychainReaderTests: XCTestCase {

    var reader: KeychainReader!

    override func setUp() {
        super.setUp()
        reader = KeychainReader()
    }

    func testToolMetadata() {
        XCTAssertEqual(reader.toolName, "get_keychain_items")
        XCTAssertFalse(reader.toolDescription.isEmpty)
    }

    func testQueryGenericPasswords() async throws {
        // This may return items or "No keychain items" — both are valid
        let result = try await reader.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Should either list items or say none found
        XCTAssertTrue(text.contains("Keychain") || text.contains("No keychain"))
    }

    func testQueryInternetPasswords() async throws {
        let result = try await reader.execute(arguments: ["item_class": "internet_password"])
        XCTAssertFalse(result.isError)
    }

    func testFilterByService() async throws {
        let result = try await reader.execute(arguments: ["service": "com.nonexistent.service.12345"])
        // Should return no items
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("No keychain items") || text.contains("Keychain Items (0"))
    }

    // MARK: - Schema validation

    func testSchemaHasServiceParameter() {
        guard let properties = reader.inputSchema["properties"] as? [String: Any],
              let service = properties["service"] as? [String: Any] else {
            XCTFail("Expected 'service' property in schema")
            return
        }
        XCTAssertEqual(service["type"] as? String, "string")
    }

    func testSchemaHasItemClassParameter_withValidEnumValues() {
        guard let properties = reader.inputSchema["properties"] as? [String: Any],
              let itemClass = properties["item_class"] as? [String: Any] else {
            XCTFail("Expected 'item_class' property in schema")
            return
        }
        XCTAssertEqual(itemClass["type"] as? String, "string")
        guard let enumValues = itemClass["enum"] as? [String] else {
            XCTFail("Expected 'enum' array in item_class schema")
            return
        }
        XCTAssertTrue(enumValues.contains("generic_password"))
        XCTAssertTrue(enumValues.contains("internet_password"))
    }

    func testSchemaType_isObject() {
        XCTAssertEqual(reader.inputSchema["type"] as? String, "object")
    }

    // MARK: - Result format

    func testResult_hasTextContent() async throws {
        let result = try await reader.execute(arguments: [:])
        guard case .text(_) = result.content.first else {
            XCTFail("Expected text content, not image or other")
            return
        }
    }

    func testResult_nonexistentService_returnsNotFound() async throws {
        // A randomly-named service should not exist in the keychain
        let uniqueService = "com.apustest.nonexistent.\(UUID().uuidString)"
        let result = try await reader.execute(arguments: ["service": uniqueService])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("No keychain items"),
                      "Nonexistent service should produce 'No keychain items' message")
    }

    // MARK: - Value redaction

    func testResult_whenItemsExist_valuesAreRedacted() async throws {
        let service = "com.apustest.redaction.\(UUID().uuidString)"
        let account = "testuser"
        let password = "super_secret_password_123"

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: password.data(using: .utf8)!
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw XCTSkip("Keychain unavailable in this test environment (SecItemAdd status: \(addStatus))")
        }

        defer {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        let result = try await reader.execute(arguments: ["service": service])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Account metadata should be visible, actual secret must not appear
        XCTAssertTrue(text.contains(account), "Should show account name in output")
        XCTAssertFalse(text.contains(password), "Should NOT expose the actual password value")
        XCTAssertTrue(text.contains("value redacted"), "Should explicitly note value is redacted")
    }

    func testToolDescription_mentionsRedaction() {
        XCTAssertTrue(reader.toolDescription.lowercased().contains("redact"),
                      "Tool description should mention that values are redacted for security")
    }
}
