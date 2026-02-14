import Foundation

/// Registry for MCP tools. Handles registration, listing, and dispatching tool calls.
final class ToolRegistry {
    private var tools: [String: MCPTool] = [:]
    private let lock = NSLock()

    /// Register a tool. Overwrites any existing tool with the same name.
    func register(_ tool: MCPTool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.toolName] = tool
    }

    /// Unregister a tool by name.
    func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        tools.removeValue(forKey: name)
    }

    /// Returns the list of tools in MCP-compatible format.
    func toolsList() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.map { tool in
            [
                "name": tool.toolName,
                "description": tool.toolDescription,
                "inputSchema": tool.inputSchema
            ]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    /// Execute a tool by name with the given arguments.
    func callTool(name: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let tool = getTool(named: name)

        guard let tool = tool else {
            let available = tools.keys.sorted().joined(separator: ", ")
            return .error("Tool '\(name)' not found. Available tools: \(available)")
        }

        return try await tool.execute(arguments: arguments)
    }

    /// Number of registered tools.
    var toolCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tools.count
    }

    /// Thread-safe tool lookup (avoids NSLock in async context).
    private func getTool(named name: String) -> MCPTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }
}
