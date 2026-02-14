import XCTest
@testable import Apus

final class ToolRegistryTests: XCTestCase {

    var registry: ToolRegistry!

    override func setUp() {
        super.setUp()
        registry = ToolRegistry()
    }

    func testRegisterAndCount() {
        XCTAssertEqual(registry.toolCount, 0)

        registry.register(MockTool(name: "tool_a"))
        XCTAssertEqual(registry.toolCount, 1)

        registry.register(MockTool(name: "tool_b"))
        XCTAssertEqual(registry.toolCount, 2)
    }

    func testRegisterOverwritesSameName() {
        registry.register(MockTool(name: "tool_a"))
        registry.register(MockTool(name: "tool_a"))
        XCTAssertEqual(registry.toolCount, 1)
    }

    func testUnregister() {
        registry.register(MockTool(name: "tool_a"))
        registry.register(MockTool(name: "tool_b"))
        XCTAssertEqual(registry.toolCount, 2)

        registry.unregister(name: "tool_a")
        XCTAssertEqual(registry.toolCount, 1)
    }

    func testUnregisterNonexistent() {
        registry.register(MockTool(name: "tool_a"))
        registry.unregister(name: "nonexistent")
        XCTAssertEqual(registry.toolCount, 1)
    }

    func testToolsListFormat() {
        registry.register(MockTool(name: "alpha_tool", description: "Alpha description"))
        registry.register(MockTool(name: "beta_tool", description: "Beta description"))

        let list = registry.toolsList()
        XCTAssertEqual(list.count, 2)

        // Should be sorted by name
        XCTAssertEqual(list[0]["name"] as? String, "alpha_tool")
        XCTAssertEqual(list[1]["name"] as? String, "beta_tool")

        // Each tool should have name, description, inputSchema
        for tool in list {
            XCTAssertNotNil(tool["name"])
            XCTAssertNotNil(tool["description"])
            XCTAssertNotNil(tool["inputSchema"])
        }
    }

    func testCallToolSuccess() async throws {
        registry.register(MockTool(name: "greeter"))
        let result = try await registry.callTool(name: "greeter", arguments: ["name": "World"])
        XCTAssertFalse(result.isError)
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("World"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testCallToolNotFound() async throws {
        let result = try await registry.callTool(name: "nonexistent", arguments: [:])
        XCTAssertTrue(result.isError)
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("not found"))
        } else {
            XCTFail("Expected error text")
        }
    }
}

// MARK: - Mock Tool

private final class MockTool: MCPTool {
    let toolName: String
    let toolDescription: String
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string"]
        ] as [String: Any]
    ]

    init(name: String, description: String = "A mock tool") {
        self.toolName = name
        self.toolDescription = description
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let name = arguments["name"] as? String ?? "unknown"
        return .text("Hello, \(name)!")
    }
}
