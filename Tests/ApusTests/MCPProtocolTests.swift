import XCTest
@testable import Apus

final class MCPProtocolTests: XCTestCase {

    var handler: MCPProtocolHandler!
    var registry: ToolRegistry!

    override func setUp() {
        super.setUp()
        registry = ToolRegistry()
        handler = MCPProtocolHandler(toolRegistry: registry)
    }

    // MARK: - Initialize

    func testInitializeReturnsServerInfo() async {
        let request = makeRequest(method: "initialize", id: 1)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        XCTAssertEqual(json?["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json?["id"] as? Int, 1)

        let result = json?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")

        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "Apus")
        XCTAssertEqual(serverInfo?["version"] as? String, "0.1.0")
    }

    func testInitializeReturnsCapabilities() async {
        let request = makeRequest(method: "initialize", id: 1)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let result = json?["result"] as? [String: Any]
        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"])
    }

    // MARK: - Ping

    func testPingReturnsEmptyResult() async {
        let request = makeRequest(method: "ping", id: 42)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        XCTAssertEqual(json?["id"] as? Int, 42)
        let result = json?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.isEmpty ?? false)
    }

    // MARK: - Notifications

    func testInitializedNotificationReturnsEmptyData() async {
        let request = makeRequest(method: "notifications/initialized", id: nil)
        let response = await handler.handleRequest(request)
        XCTAssertTrue(response.isEmpty)
        XCTAssertTrue(handler.isInitialized)
    }

    // MARK: - Tools List

    func testToolsListReturnsEmptyWhenNoToolsRegistered() async {
        let request = makeRequest(method: "tools/list", id: 1)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let result = json?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertNotNil(tools)
        XCTAssertEqual(tools?.count, 0)
    }

    func testToolsListReturnsRegisteredTools() async {
        registry.register(StubTool(name: "test_tool", description: "A test tool"))
        registry.register(StubTool(name: "another_tool", description: "Another tool"))

        let request = makeRequest(method: "tools/list", id: 1)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let result = json?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 2)
    }

    // MARK: - Tools Call

    func testToolsCallExecutesTool() async {
        let stub = StubTool(name: "echo", description: "Echoes input")
        registry.register(stub)

        let params: [String: Any] = [
            "name": "echo",
            "arguments": ["message": "hello"]
        ]
        let request = makeRequest(method: "tools/call", id: 1, params: params)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)

        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["type"] as? String, "text")
    }

    func testToolsCallWithMissingNameReturnsError() async {
        let request = makeRequest(method: "tools/call", id: 1, params: [:])
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let error = json?["error"] as? [String: Any]
        XCTAssertNotNil(error)
        XCTAssertEqual(error?["code"] as? Int, -32602)
    }

    func testToolsCallWithUnknownToolReturnsToolError() async {
        let params: [String: Any] = ["name": "nonexistent"]
        let request = makeRequest(method: "tools/call", id: 1, params: params)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let result = json?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
    }

    // MARK: - Error Handling

    func testInvalidJSONReturnsParseError() async {
        let response = await handler.handleRequest(Data("not json".utf8))
        let json = parseResponse(response)

        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32700)
    }

    func testMissingMethodReturnsInvalidRequest() async {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1])
        let response = await handler.handleRequest(data)
        let json = parseResponse(response)

        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32600)
    }

    func testUnknownMethodReturnsMethodNotFound() async {
        let request = makeRequest(method: "unknown/method", id: 1)
        let response = await handler.handleRequest(request)
        let json = parseResponse(response)

        let error = json?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    // MARK: - Helpers

    private func makeRequest(method: String, id: Int?, params: [String: Any]? = nil) -> Data {
        var json: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id = id { json["id"] = id }
        if let params = params { json["params"] = params }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func parseResponse(_ data: Data) -> [String: Any]? {
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Stub Tool for Testing

private final class StubTool: MCPTool {
    let toolName: String
    let toolDescription: String
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "message": ["type": "string", "description": "A message"]
        ] as [String: Any]
    ]

    init(name: String, description: String) {
        self.toolName = name
        self.toolDescription = description
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let msg = arguments["message"] as? String ?? "no message"
        return .text("Echo: \(msg)")
    }
}
