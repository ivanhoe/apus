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
        XCTAssertTrue(tool.toolDescription.contains("source_code"))
    }

    // MARK: - Schema Tests

    func testSchemaIsObject() {
        let schema = tool.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testSchemaIncludesSourceCode() {
        let schema = tool.inputSchema
        let properties = schema["properties"] as? [String: Any]
        let sourceCodeParam = properties?["source_code"] as? [String: Any]
        XCTAssertNotNil(sourceCodeParam)
        XCTAssertEqual(sourceCodeParam?["type"] as? String, "string")
    }

    func testSchemaIncludesDylibPath() {
        let schema = tool.inputSchema
        let properties = schema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["dylib_path"])
    }

    func testSchemaNoLongerRequiresDylibPath() {
        let schema = tool.inputSchema
        let required = schema["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertTrue(required!.isEmpty, "required should be empty — both source_code and dylib_path are optional")
    }

    func testSchemaIncludesScreenshotParam() {
        let schema = tool.inputSchema
        let properties = schema["properties"] as? [String: Any]
        let screenshotParam = properties?["include_screenshot"] as? [String: Any]
        XCTAssertNotNil(screenshotParam)
        XCTAssertEqual(screenshotParam?["type"] as? String, "boolean")
    }

    func testSchemaIncludesOriginalPath() {
        let schema = tool.inputSchema
        let properties = schema["properties"] as? [String: Any]
        let originalPathParam = properties?["original_path"] as? [String: Any]
        XCTAssertNotNil(originalPathParam)
        XCTAssertEqual(originalPathParam?["type"] as? String, "string")
    }

    func testDescriptionMentionsSourceCode() {
        XCTAssertTrue(tool.toolDescription.contains("source_code"))
        XCTAssertTrue(tool.toolDescription.contains("WORKFLOW"))
        XCTAssertTrue(tool.toolDescription.contains("WHAT WORKS"))
        XCTAssertTrue(tool.toolDescription.contains("RULES"))
        XCTAssertTrue(tool.toolDescription.contains("EXAMPLE"))
    }

    // MARK: - Validation Tests

    func testRejectsNoParameters() async throws {
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("source_code") || text.contains("dylib_path"),
                       "Error should mention the expected parameters")
    }

    func testAcceptsDylibPathAlone() async throws {
        // Should fail because file doesn't exist, NOT because of missing params
        let result = try await tool.execute(arguments: [
            "dylib_path": "/tmp/nonexistent_\(UUID().uuidString).dylib"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"), "Should fail with 'not found', not a param error")
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
}
