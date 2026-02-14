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
}
