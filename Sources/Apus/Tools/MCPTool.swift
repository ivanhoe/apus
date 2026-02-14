import Foundation

/// Protocol that all MCP tools must conform to.
public protocol MCPTool: AnyObject {
    /// Unique tool name used in MCP tool calls
    var toolName: String { get }

    /// Human-readable description of what the tool does
    var toolDescription: String { get }

    /// JSON Schema describing the tool's input parameters
    var inputSchema: [String: Any] { get }

    /// Execute the tool with the given arguments
    func execute(arguments: [String: Any]) async throws -> MCPToolResult
}

/// Result returned by an MCP tool execution.
public struct MCPToolResult {
    public let content: [MCPContent]
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [.text(text)])
    }

    public static func error(_ message: String) -> MCPToolResult {
        MCPToolResult(content: [.text(message)], isError: true)
    }
}

/// Content types that can be returned by MCP tools.
public enum MCPContent {
    case text(String)
    case image(data: Data, mimeType: String)

    func toJSON() -> [String: Any] {
        switch self {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let data, let mimeType):
            return [
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": mimeType
            ]
        }
    }
}
