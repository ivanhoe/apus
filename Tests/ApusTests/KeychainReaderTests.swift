import XCTest
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
}
