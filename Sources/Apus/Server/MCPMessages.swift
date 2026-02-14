import Foundation

// MARK: - JSON-RPC 2.0 Error Codes

enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

// MARK: - Server Info Constants

enum MCPServerInfo {
    static let name = "Apus"
    static let version = "0.1.0"
    static let protocolVersion = "2024-11-05"
}

// MARK: - MCP Method Names

enum MCPMethod {
    static let initialize = "initialize"
    static let initialized = "notifications/initialized"
    static let ping = "ping"
    static let toolsList = "tools/list"
    static let toolsCall = "tools/call"
}

// MARK: - JSON-RPC Response Builders

enum JSONRPCResponse {

    static func success(id: Any?, result: [String: Any]) -> Data {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id {
            response["id"] = id
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    static func error(id: Any?, code: Int, message: String) -> Data {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ] as [String: Any]
        ]
        if let id = id {
            response["id"] = id
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}
