import XCTest
@testable import Apus

final class WebSocketIntegrationTests: XCTestCase {
    private var server: WebSocketServer!
    private var toolRegistry: ToolRegistry!
    private var testPort: UInt16 = 0

    /// Atomic counter to assign a unique port per test, avoiding bind conflicts.
    private static let portLock = NSLock()
    private static var nextPort: UInt16 = 19850

    private static func allocatePort() -> UInt16 {
        portLock.lock()
        defer { portLock.unlock() }
        let port = nextPort
        nextPort += 1
        return port
    }

    override func setUp() async throws {
        try await super.setUp()
        testPort = Self.allocatePort()
        toolRegistry = ToolRegistry()
        let handler = MCPProtocolHandler(toolRegistry: toolRegistry)
        let subManager = SubscriptionManager()

        server = WebSocketServer(handler: handler)
        server.subscriptionManager = subManager
        try server.start(port: testPort, bindAddress: "127.0.0.1")
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        toolRegistry = nil
        try await super.tearDown()
    }

    // MARK: - Connection

    func testConnect_andReceiveMessage() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        // Send initialize
        let initMsg = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        ws.send(.string(initMsg)) { error in
            XCTAssertNil(error)
        }

        // Receive response
        let message = try await ws.receiveString()
        let json = try parseJSON(message)
        let result = json["result"] as? [String: Any]

        XCTAssertNotNil(result)
        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "Apus")
    }

    // MARK: - MCP Protocol

    func testPing_returnsEmptyResult() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let pingMsg = #"{"jsonrpc":"2.0","id":42,"method":"ping","params":{}}"#
        ws.send(.string(pingMsg)) { error in
            XCTAssertNil(error)
        }

        let message = try await ws.receiveString()
        let json = try parseJSON(message)

        XCTAssertEqual(json["id"] as? Int, 42)
        XCTAssertNotNil(json["result"])
    }

    func testToolsList_returnsTools() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let listMsg = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ws.send(.string(listMsg)) { error in
            XCTAssertNil(error)
        }

        let message = try await ws.receiveString()
        let json = try parseJSON(message)
        let result = json["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]

        XCTAssertNotNil(tools)
    }

    func testInvalidMethod_returnsError() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let msg = #"{"jsonrpc":"2.0","id":3,"method":"nonexistent","params":{}}"#
        ws.send(.string(msg)) { error in
            XCTAssertNil(error)
        }

        let message = try await ws.receiveString()
        let json = try parseJSON(message)
        let error = json["error"] as? [String: Any]

        XCTAssertNotNil(error)
        XCTAssertEqual(error?["code"] as? Int, MCPErrorCode.methodNotFound)
    }

    // MARK: - Subscriptions

    func testSubscribe_returnsSubscribedChannels() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        let msg = #"{"jsonrpc":"2.0","id":10,"method":"subscribe","params":{"channels":["logs","network"]}}"#
        ws.send(.string(msg)) { error in
            XCTAssertNil(error)
        }

        let message = try await ws.receiveString()
        let json = try parseJSON(message)
        let result = json["result"] as? [String: Any]
        let subscribed = result?["subscribed"] as? [String]

        XCTAssertEqual(Set(subscribed ?? []), ["logs", "network"])
    }

    func testUnsubscribe_returnsUnsubscribedChannels() async throws {
        let ws = try makeWebSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }

        // Subscribe first
        let subMsg = #"{"jsonrpc":"2.0","id":10,"method":"subscribe","params":{"channels":["logs"]}}"#
        ws.send(.string(subMsg)) { _ in }
        _ = try await ws.receiveString()

        // Unsubscribe
        let unsubMsg = #"{"jsonrpc":"2.0","id":11,"method":"unsubscribe","params":{"channels":["logs"]}}"#
        ws.send(.string(unsubMsg)) { error in
            XCTAssertNil(error)
        }

        let message = try await ws.receiveString()
        let json = try parseJSON(message)
        let result = json["result"] as? [String: Any]
        let unsubscribed = result?["unsubscribed"] as? [String]

        XCTAssertEqual(unsubscribed, ["logs"])
    }

    // MARK: - Multiple Connections

    func testMultipleConnections_eachGetsOwnResponse() async throws {
        let ws1 = try makeWebSocket()
        let ws2 = try makeWebSocket()
        defer {
            ws1.cancel(with: .goingAway, reason: nil)
            ws2.cancel(with: .goingAway, reason: nil)
        }

        // Send different requests on each connection
        ws1.send(.string(#"{"jsonrpc":"2.0","id":100,"method":"ping","params":{}}"#)) { _ in }
        ws2.send(.string(#"{"jsonrpc":"2.0","id":200,"method":"ping","params":{}}"#)) { _ in }

        let msg1 = try await ws1.receiveString()
        let msg2 = try await ws2.receiveString()

        let json1 = try parseJSON(msg1)
        let json2 = try parseJSON(msg2)

        XCTAssertEqual(json1["id"] as? Int, 100)
        XCTAssertEqual(json2["id"] as? Int, 200)
    }

    // MARK: - Connection Limit

    func testConnectionLimit_rejectsExcessConnections() async throws {
        var connections: [URLSessionWebSocketTask] = []
        defer {
            for conn in connections {
                conn.cancel(with: .goingAway, reason: nil)
            }
        }

        // Fill up to the max
        for _ in 0..<WebSocketConnectionManager.maxConnections {
            let ws = try makeWebSocket()
            // Verify connection is alive with a ping
            ws.send(.string(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}"#)) { _ in }
            _ = try await ws.receiveString()
            connections.append(ws)
        }

        XCTAssertEqual(server.connectionManager.count, WebSocketConnectionManager.maxConnections)
    }

    // MARK: - Server Lifecycle

    func testServerStartStop_isRunning() throws {
        XCTAssertTrue(server.isRunning)
        server.stop()
        XCTAssertFalse(server.isRunning)
    }

    func testServerStop_disconnectsClients() async throws {
        let ws = try makeWebSocket()

        // Verify connected
        ws.send(.string(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}"#)) { _ in }
        _ = try await ws.receiveString()

        // Stop server
        server.stop()

        // Wait for disconnection to propagate
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(server.connectionManager.count, 0)
    }

    // MARK: - Helpers

    private func makeWebSocket() throws -> URLSessionWebSocketTask {
        let url = URL(string: "ws://127.0.0.1:\(testPort)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        return task
    }

    private func parseJSON(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestError.invalidJSON
        }
        return json
    }

    private enum TestError: Error {
        case invalidJSON
        case unexpectedMessageType
    }
}

// MARK: - URLSessionWebSocketTask Helpers

private extension URLSessionWebSocketTask {
    func receiveString() async throws -> String {
        let message = try await receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "WebSocketTest", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Binary message received instead of text"
                ])
            }
            return text
        @unknown default:
            throw NSError(domain: "WebSocketTest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unknown message type"
            ])
        }
    }
}
