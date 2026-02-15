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

    // MARK: - Response Cache tests

    func testCacheReturnUnchangedOnIdenticalResponse() async throws {
        registry.register(MockTool(name: "greeter"))

        let result1 = try await registry.callTool(name: "greeter", arguments: ["name": "World"])
        XCTAssertFalse(result1.isError)
        if case .text(let text) = result1.content.first {
            XCTAssertTrue(text.contains("Hello, World!"))
        }

        // Second call with same args → should be cached
        let result2 = try await registry.callTool(name: "greeter", arguments: ["name": "World"])
        if case .text(let text) = result2.content.first {
            XCTAssertEqual(text, "(unchanged since last call)")
        } else {
            XCTFail("Expected text content")
        }
    }

    func testCacheReturnsFullResponseOnDifferentArgs() async throws {
        registry.register(MockTool(name: "greeter"))

        _ = try await registry.callTool(name: "greeter", arguments: ["name": "World"])

        // Different args → full response
        let result2 = try await registry.callTool(name: "greeter", arguments: ["name": "Swift"])
        if case .text(let text) = result2.content.first {
            XCTAssertTrue(text.contains("Hello, Swift!"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testCacheSkipsErrors() async throws {
        registry.register(ErrorTool(name: "failing_tool"))

        let result1 = try await registry.callTool(name: "failing_tool", arguments: [:])
        XCTAssertTrue(result1.isError)

        // Second call should still return the error, not "(unchanged)"
        let result2 = try await registry.callTool(name: "failing_tool", arguments: [:])
        XCTAssertTrue(result2.isError)
        if case .text(let text) = result2.content.first {
            XCTAssertTrue(text.contains("Something went wrong"))
        }
    }

    func testCacheSkipsExcludedTools() async throws {
        registry.register(MockTool(name: "execute_action"))

        let result1 = try await registry.callTool(name: "execute_action", arguments: ["name": "test"])
        let result2 = try await registry.callTool(name: "execute_action", arguments: ["name": "test"])

        // Both should return full response (not cached)
        if case .text(let text1) = result1.content.first,
           case .text(let text2) = result2.content.first {
            XCTAssertEqual(text1, text2)
            XCTAssertTrue(text1.contains("Hello, test!"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testCacheInvalidatesOnChange() async throws {
        let tool = CountingTool(name: "counter")
        registry.register(tool)

        let result1 = try await registry.callTool(name: "counter", arguments: [:])
        if case .text(let text) = result1.content.first {
            XCTAssertEqual(text, "count: 1")
        }

        // Second call returns different content → full response
        let result2 = try await registry.callTool(name: "counter", arguments: [:])
        if case .text(let text) = result2.content.first {
            XCTAssertEqual(text, "count: 2")
        }
    }

    func testClearCache() async throws {
        registry.register(MockTool(name: "greeter"))

        _ = try await registry.callTool(name: "greeter", arguments: ["name": "World"])
        registry.clearCache()

        // After clearing, should return full response
        let result = try await registry.callTool(name: "greeter", arguments: ["name": "World"])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Hello, World!"))
        } else {
            XCTFail("Expected text content")
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

private final class ErrorTool: MCPTool {
    let toolName: String
    let toolDescription = "A tool that always errors"
    let inputSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    init(name: String) { self.toolName = name }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        return .error("Something went wrong")
    }
}

private final class CountingTool: MCPTool {
    let toolName: String
    let toolDescription = "A tool that returns incrementing counts"
    let inputSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    private var callCount = 0

    init(name: String) { self.toolName = name }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        callCount += 1
        return .text("count: \(callCount)")
    }
}
