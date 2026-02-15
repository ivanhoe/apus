import XCTest
@testable import Apus

final class HotReloadToolTests: XCTestCase {

    var tool: HotReloadTool!

    override func setUp() {
        super.setUp()
        tool = HotReloadTool()
    }

    func testToolMetadata() {
        XCTAssertEqual(tool.toolName, "hot_reload")
        XCTAssertFalse(tool.toolDescription.isEmpty)
        XCTAssertTrue(tool.toolDescription.contains("dylib"))
    }

    func testSchemaRequiresDylibPath() {
        let schema = tool.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")

        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["dylib_path"])

        let required = schema["required"] as? [String]
        XCTAssertEqual(required, ["dylib_path"])
    }

    func testRejectsPathOutsideTmp() async throws {
        let result = try await tool.execute(arguments: [
            "dylib_path": "/Users/evil/injection.dylib"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Security"), "Should mention security restriction")
        XCTAssertTrue(text.contains("/tmp/"), "Should mention /tmp/ requirement")
    }

    func testRejectsHomeDirPath() async throws {
        let result = try await tool.execute(arguments: [
            "dylib_path": "/home/user/injection.dylib"
        ])
        XCTAssertTrue(result.isError)
    }

    func testRejectsNonexistentFile() async throws {
        let result = try await tool.execute(arguments: [
            "dylib_path": "/tmp/nonexistent_\(UUID().uuidString).dylib"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"), "Should report file not found")
    }

    func testRejectsMissingParameter() async throws {
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("dylib_path"), "Should mention missing parameter")
    }
}
