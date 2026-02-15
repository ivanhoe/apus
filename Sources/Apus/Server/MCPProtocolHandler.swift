import Foundation

/// Handles MCP JSON-RPC 2.0 requests and routes them to the appropriate handler.
final class MCPProtocolHandler {
    let toolRegistry: ToolRegistry
    private(set) var isInitialized = false

    init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    /// Process a raw JSON-RPC request and return the response data.
    func handleRequest(_ data: Data) async -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return JSONRPCResponse.error(
                id: nil,
                code: MCPErrorCode.parseError,
                message: "Parse error: invalid JSON"
            )
        }

        guard let method = json["method"] as? String else {
            return JSONRPCResponse.error(
                id: json["id"],
                code: MCPErrorCode.invalidRequest,
                message: "Invalid Request: missing 'method' field"
            )
        }

        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case MCPMethod.initialize:
            return handleInitialize(id: id, params: params)
        case MCPMethod.initialized:
            isInitialized = true
            // Notification — no response
            return Data()
        case MCPMethod.ping:
            return JSONRPCResponse.success(id: id, result: [:])
        case MCPMethod.toolsList:
            return handleToolsList(id: id, params: params)
        case MCPMethod.toolsCall:
            return await handleToolsCall(id: id, params: params)
        default:
            return JSONRPCResponse.error(
                id: id,
                code: MCPErrorCode.methodNotFound,
                message: "Method not found: \(method)"
            )
        }
    }

    // MARK: - Method Handlers

    private func handleInitialize(id: Any?, params: [String: Any]) -> Data {
        var serverInfo: [String: Any] = [
            "name": MCPServerInfo.name,
            "version": MCPServerInfo.version
        ]
        if let projectRoot = Apus.shared.projectRoot {
            serverInfo["projectRoot"] = projectRoot
        }
        let result: [String: Any] = [
            "protocolVersion": MCPServerInfo.protocolVersion,
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ] as [String: Any],
            "serverInfo": serverInfo
        ]
        return JSONRPCResponse.success(id: id, result: result)
    }

    private func handleToolsList(id: Any?, params: [String: Any]) -> Data {
        let tools = toolRegistry.toolsList()
        return JSONRPCResponse.success(id: id, result: ["tools": tools])
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) async -> Data {
        guard let name = params["name"] as? String else {
            return JSONRPCResponse.error(
                id: id,
                code: MCPErrorCode.invalidParams,
                message: "Invalid params: missing 'name' field"
            )
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let result = try await toolRegistry.callTool(name: name, arguments: arguments)
            let content = result.content.map { $0.toJSON() }
            let response: [String: Any] = [
                "content": content,
                "isError": result.isError
            ]
            return JSONRPCResponse.success(id: id, result: response)
        } catch {
            let response: [String: Any] = [
                "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                "isError": true
            ]
            return JSONRPCResponse.success(id: id, result: response)
        }
    }
}
