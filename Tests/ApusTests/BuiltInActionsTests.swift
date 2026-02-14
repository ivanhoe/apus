import XCTest
@testable import Apus

final class BuiltInActionsTests: XCTestCase {

    var runner: ActionRunner!

    override func setUp() {
        super.setUp()
        runner = ActionRunner()
        BuiltInActions.register(on: runner)
    }

    override func tearDown() {
        // Clean up test keys
        UserDefaults.standard.removeObject(forKey: "apusBuiltInTest.key")
        UserDefaults.standard.removeObject(forKey: "apusBuiltInTest.toDelete")
        // Clean up test files
        let home = NSHomeDirectory()
        let testFile = (home as NSString).appendingPathComponent("Documents/apus_builtin_test.txt")
        try? FileManager.default.removeItem(atPath: testFile)
        super.tearDown()
    }

    func testAllActionsRegistered() async throws {
        let result = try await runner.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Verify key built-in actions are registered
        XCTAssertTrue(text.contains("clear_url_cache"))
        XCTAssertTrue(text.contains("clear_cookies"))
        XCTAssertTrue(text.contains("clear_tmp"))
        XCTAssertTrue(text.contains("set_user_default"))
        XCTAssertTrue(text.contains("delete_user_default"))
        XCTAssertTrue(text.contains("clear_all_user_defaults"))
        XCTAssertTrue(text.contains("delete_file"))
        XCTAssertTrue(text.contains("write_file"))
    }

    func testClearURLCache() async throws {
        let result = try await runner.execute(arguments: [
            "name": "clear_url_cache"
        ])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("cache cleared") || text.contains("Cache cleared") || text.contains("freed"))
    }

    func testClearCookies() async throws {
        let result = try await runner.execute(arguments: [
            "name": "clear_cookies"
        ])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.lowercased().contains("cookies") || text.lowercased().contains("deleted"))
    }

    func testSetUserDefault() async throws {
        let result = try await runner.execute(arguments: [
            "name": "set_user_default",
            "arguments": ["key": "apusBuiltInTest.key", "value": "testValue"]
        ])
        XCTAssertFalse(result.isError)

        // Verify the value was actually set
        XCTAssertEqual(UserDefaults.standard.string(forKey: "apusBuiltInTest.key"), "testValue")
    }

    func testSetUserDefaultMissingKey() async throws {
        let result = try await runner.execute(arguments: [
            "name": "set_user_default",
            "arguments": ["value": "nokey"]
        ])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Error") || text.contains("required"))
    }

    func testDeleteUserDefault() async throws {
        UserDefaults.standard.set("toDelete", forKey: "apusBuiltInTest.toDelete")

        let result = try await runner.execute(arguments: [
            "name": "delete_user_default",
            "arguments": ["key": "apusBuiltInTest.toDelete"]
        ])
        XCTAssertFalse(result.isError)

        XCTAssertNil(UserDefaults.standard.object(forKey: "apusBuiltInTest.toDelete"))
    }

    func testWriteFile() async throws {
        let result = try await runner.execute(arguments: [
            "name": "write_file",
            "arguments": ["path": "Documents/apus_builtin_test.txt", "content": "Hello from test"]
        ])
        XCTAssertFalse(result.isError)

        // Verify file was written
        let home = NSHomeDirectory()
        let filePath = (home as NSString).appendingPathComponent("Documents/apus_builtin_test.txt")
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertEqual(content, "Hello from test")
    }

    func testDeleteFile() async throws {
        // Create a file first
        let home = NSHomeDirectory()
        let filePath = (home as NSString).appendingPathComponent("Documents/apus_builtin_test.txt")
        try "temp".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await runner.execute(arguments: [
            "name": "delete_file",
            "arguments": ["path": "Documents/apus_builtin_test.txt"]
        ])
        XCTAssertFalse(result.isError)

        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func testDeleteFileSandboxEnforcement() async throws {
        // Use an absolute path outside the sandbox
        let result = try await runner.execute(arguments: [
            "name": "delete_file",
            "arguments": ["path": "/etc/passwd"]
        ])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Error") || text.contains("sandbox") || text.contains("not found"))
    }

    func testDeleteNonexistentFile() async throws {
        let result = try await runner.execute(arguments: [
            "name": "delete_file",
            "arguments": ["path": "Documents/does_not_exist_12345.txt"]
        ])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Error") || text.contains("not found"))
    }
}
