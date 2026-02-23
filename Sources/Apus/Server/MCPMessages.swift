import Foundation

// MARK: - JSON-RPC 2.0 Error Codes

/// Standard JSON-RPC 2.0 error codes used in MCP protocol responses.
enum MCPErrorCode {
    /// The JSON payload could not be parsed (`-32700`).
    static let parseError = -32700
    /// The request object is not a valid JSON-RPC request (`-32600`).
    static let invalidRequest = -32600
    /// The requested method does not exist (`-32601`).
    static let methodNotFound = -32601
    /// The method parameters are invalid (`-32602`).
    static let invalidParams = -32602
    /// An internal server error occurred (`-32603`).
    static let internalError = -32603
}

// MARK: - Server Info Constants

/// Metadata constants for the Apus MCP server identity and protocol version.
enum MCPServerInfo {
    /// Human-readable server name returned during initialization.
    static let name = "Apus"
    /// Semantic version of the Apus server.
    static let version = "0.2.0"
    /// MCP protocol version this server implements.
    static let protocolVersion = "2024-11-05"
}

// MARK: - MCP Method Names

/// Well-known MCP JSON-RPC method name constants.
enum MCPMethod {
    /// Client requests server capabilities and info.
    static let initialize = "initialize"
    /// Client notification that initialization is complete.
    static let initialized = "notifications/initialized"
    /// Heartbeat check.
    static let ping = "ping"
    /// Client requests the list of available tools.
    static let toolsList = "tools/list"
    /// Client invokes a specific tool by name.
    static let toolsCall = "tools/call"
}

// MARK: - JSON-RPC Response Builders

/// Factory methods for building JSON-RPC 2.0 response payloads.
enum JSONRPCResponse {

    /// Builds a successful JSON-RPC response.
    /// - Parameters:
    ///   - id: The request identifier to echo back (may be `nil` for notifications).
    ///   - result: The result dictionary to include in the response.
    /// - Returns: Serialized JSON data ready to send over the wire.
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

    /// Builds a JSON-RPC error response.
    /// - Parameters:
    ///   - id: The request identifier to echo back (may be `nil` for notifications).
    ///   - code: A JSON-RPC error code (see ``MCPErrorCode``).
    ///   - message: A human-readable description of the error.
    /// - Returns: Serialized JSON data ready to send over the wire.
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
