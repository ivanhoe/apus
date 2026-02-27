import XCTest
@testable import Apus

final class UserDefaultsReaderTests: XCTestCase {

    var reader: UserDefaultsReader!

    override func setUp() {
        super.setUp()
        reader = UserDefaultsReader()
    }

    override func tearDown() {
        // Clean up test keys
        UserDefaults.standard.removeObject(forKey: "apusTest.name")
        UserDefaults.standard.removeObject(forKey: "apusTest.count")
        UserDefaults.standard.removeObject(forKey: "apusTest.flag")
        UserDefaults.standard.removeObject(forKey: "other.key")
        super.tearDown()
    }

    func testToolMetadata() {
        XCTAssertEqual(reader.toolName, "get_user_defaults")
        XCTAssertFalse(reader.toolDescription.isEmpty)
    }

    func testReadAllDefaults() async throws {
        UserDefaults.standard.set("Ivan", forKey: "apusTest.name")

        let result = try await reader.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("apusTest.name"))
        XCTAssertTrue(text.contains("Ivan"))
    }

    func testFilterByPrefix() async throws {
        UserDefaults.standard.set("Ivan", forKey: "apusTest.name")
        UserDefaults.standard.set(42, forKey: "apusTest.count")
        UserDefaults.standard.set("other", forKey: "other.key")

        let result = try await reader.execute(arguments: ["prefix": "apusTest"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("apusTest.name"))
        XCTAssertTrue(text.contains("apusTest.count"))
        XCTAssertFalse(text.contains("other.key"))
    }

    func testNoMatchingPrefix() async throws {
        let result = try await reader.execute(arguments: ["prefix": "nonExistentPrefix.zzz"])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("No UserDefaults entries found"))
    }

    func testFormatsDataValues() async throws {
        UserDefaults.standard.set(Data([0x01, 0x02, 0x03]), forKey: "apusTest.data")
        defer { UserDefaults.standard.removeObject(forKey: "apusTest.data") }

        let result = try await reader.execute(arguments: ["prefix": "apusTest.data"])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("<Data: 3 bytes>"))
    }

    func testFormatsDateValues() async throws {
        let date = Date()
        UserDefaults.standard.set(date, forKey: "apusTest.date")
        defer { UserDefaults.standard.removeObject(forKey: "apusTest.date") }

        let result = try await reader.execute(arguments: ["prefix": "apusTest.date"])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // ISO8601 date format contains "T" and "Z"
        XCTAssertTrue(text.contains("T"))
    }

    // MARK: - Schema validation

    func testSchemaHasPrefixParameter() {
        guard let properties = reader.inputSchema["properties"] as? [String: Any],
              let prefix = properties["prefix"] as? [String: Any] else {
            XCTFail("Expected 'prefix' property in schema")
            return
        }
        XCTAssertEqual(prefix["type"] as? String, "string")
    }

    func testSchemaHasIncludeSystemParameter() {
        guard let properties = reader.inputSchema["properties"] as? [String: Any],
              let includeSystem = properties["include_system"] as? [String: Any] else {
            XCTFail("Expected 'include_system' property in schema")
            return
        }
        XCTAssertEqual(includeSystem["type"] as? String, "boolean")
    }

    func testSchemaType_isObject() {
        XCTAssertEqual(reader.inputSchema["type"] as? String, "object")
    }

    // MARK: - System key filtering

    func testSystemKeysExcludedByDefault() async throws {
        // Without include_system, common Apple-prefixed keys should be absent
        let result = try await reader.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Keys like "AppleLanguages" are always in standard UserDefaults
        // but should be hidden unless include_system is true
        let lines = text.components(separatedBy: "\n")
        let appleKeyLines = lines.filter { line in
            ["Apple", "NS", "com.apple"].contains(where: { prefix in
                line.hasPrefix(prefix)
            })
        }
        XCTAssertTrue(appleKeyLines.isEmpty,
                      "Apple/NS system keys should be excluded by default")
    }

    func testIncludeSystemKeys_doesNotReturnError() async throws {
        let result = try await reader.execute(arguments: ["include_system": true])
        XCTAssertFalse(result.isError)
    }

    // MARK: - Value type formatting

    func testBooleanValue_isFormatted() async throws {
        UserDefaults.standard.set(true, forKey: "apusTest.flag")

        let result = try await reader.execute(arguments: ["prefix": "apusTest.flag"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertFalse(result.isError)
        XCTAssertTrue(text.contains("apusTest.flag"), "Should show the boolean key")
    }

    func testIntegerValue_isFormatted() async throws {
        UserDefaults.standard.set(42, forKey: "apusTest.count")

        let result = try await reader.execute(arguments: ["prefix": "apusTest.count"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("apusTest.count"))
        XCTAssertTrue(text.contains("42"))
    }

    func testArrayValue_doesNotCrash() async throws {
        let key = "apusTest.array"
        UserDefaults.standard.set(["alpha", "beta", "gamma"], forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let result = try await reader.execute(arguments: ["prefix": key])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains(key), "Should show the array key in output")
    }

    // MARK: - Large value truncation

    func testLargeStringValue_isTruncated() async throws {
        let longString = String(repeating: "x", count: 300)
        let key = "apusTest.long"
        UserDefaults.standard.set(longString, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let result = try await reader.execute(arguments: ["prefix": key])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // The implementation truncates at 200 chars and appends "... (N chars)"
        XCTAssertTrue(text.contains("..."), "Long values should be truncated with '...'")
        XCTAssertTrue(text.contains("chars"), "Truncated value should show total char count")
        XCTAssertFalse(text.contains(longString), "Full long string should not appear in output")
    }

    // MARK: - Output format

    func testResult_hasTextContent() async throws {
        UserDefaults.standard.set("value", forKey: "apusTest.name")
        let result = try await reader.execute(arguments: ["prefix": "apusTest"])
        guard case .text(_) = result.content.first else {
            XCTFail("Expected text content, not image or other type")
            return
        }
    }

    func testResult_showsEntryCount() async throws {
        UserDefaults.standard.set("a", forKey: "apusTest.name")
        UserDefaults.standard.set(1, forKey: "apusTest.count")

        let result = try await reader.execute(arguments: ["prefix": "apusTest"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("entries"), "Output header should mention the entry count")
    }
}
