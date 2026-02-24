import Foundation

/// Registry for MCP tools. Handles registration, listing, and dispatching tool calls.
final class ToolRegistry {
    private var tools: [String: MCPTool] = [:]
    private let lock = NSLock()

    /// Cache: maps "toolName:argsHash" → hash of last text response
    private var responseCache: [String: Int] = [:]
    private let cacheLock = NSLock()

    /// Tools excluded from response caching (side-effectful or non-deterministic)
    private let cacheExcludedTools: Set<String> = ["execute_action", "get_screenshot", "get_view_snapshots", "edit_project_file", "highlight_view", "modify_view", "hot_reload"]

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

        let result = try await tool.execute(arguments: arguments)

        // Skip cache for excluded tools, errors, or responses containing images
        guard !cacheExcludedTools.contains(name),
              !result.isError,
              !result.content.contains(where: { if case .image = $0 { return true }; return false })
        else {
            return result
        }

        // Extract text content for hashing
        let textContent = result.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined()

        let responseHash = textContent.hashValue
        let key = cacheKey(name: name, arguments: arguments)

        if checkAndUpdateCache(key: key, hash: responseHash) {
            return .text("(unchanged since last call)")
        }

        return result
    }

    /// Number of registered tools.
    var toolCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tools.count
    }

    /// Clear the response cache (e.g. when state changes significantly).
    func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        responseCache.removeAll()
    }

    /// Thread-safe cache check + update. Returns true if response is unchanged.
    private func checkAndUpdateCache(key: String, hash: Int) -> Bool {
        cacheLock.lock()
        let previousHash = responseCache[key]
        responseCache[key] = hash
        cacheLock.unlock()
        return previousHash == hash
    }

    /// Thread-safe tool lookup (avoids NSLock in async context).
    private func getTool(named name: String) -> MCPTool? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name]
    }

    /// Build a stable cache key from tool name + arguments.
    private func cacheKey(name: String, arguments: [String: Any]) -> String {
        // Sort keys for deterministic ordering
        let argsString = arguments.keys.sorted().map { key in
            "\(key):\(arguments[key] ?? "nil")"
        }.joined(separator: ",")
        return "\(name):\(argsString)"
    }
}
