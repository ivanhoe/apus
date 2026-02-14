import Foundation

/// A registered action that an AI agent can trigger.
struct RegisteredAction {
    let name: String
    let description: String
    let handler: ([String: Any]) async throws -> String?
}

/// MCP tool that lets AI agents execute developer-registered actions.
/// This is the closest equivalent to "eval" in a compiled language —
/// developers register named closures that the agent can discover and invoke.
///
/// Register actions via `Apus.shared.action("name", description: "...") { ... }`
final class ActionRunner: MCPTool {
    var toolName: String { "execute_action" }
    var toolDescription: String {
        "Execute a developer-registered action by name. Actions are closures registered via Apus.action(). Call without 'name' to list all available actions. Some actions accept additional arguments (key, value, path, etc.)."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "The action name to execute. Omit to list all available actions."
                ] as [String: Any],
                "arguments": [
                    "type": "object",
                    "description": "Optional arguments to pass to the action (e.g. {\"key\": \"app.theme\", \"value\": \"dark\"})"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    private var actions: [String: RegisteredAction] = [:]
    private let lock = NSLock()

    /// Register an action with arguments.
    func register(name: String, description: String, handler: @escaping ([String: Any]) async throws -> String?) {
        lock.lock()
        defer { lock.unlock() }
        actions[name] = RegisteredAction(name: name, description: description, handler: handler)
    }

    /// Register a simple action without arguments.
    func register(name: String, description: String, handler: @escaping () async throws -> String?) {
        register(name: name, description: description) { _ in try await handler() }
    }

    /// Unregister an action by name.
    func unregister(name: String) {
        lock.lock()
        defer { lock.unlock() }
        actions.removeValue(forKey: name)
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let name = arguments["name"] as? String else {
            return listActions()
        }

        let action = getAction(named: name)

        guard let action = action else {
            let available = getActionNames().joined(separator: ", ")
            return .error("Action '\(name)' not found. Available actions: \(available)")
        }

        let actionArgs = arguments["arguments"] as? [String: Any] ?? [:]

        do {
            let result = try await action.handler(actionArgs)
            let message = result ?? "Action '\(name)' executed successfully."
            return .text(message)
        } catch {
            return .error("Action '\(name)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Thread-safe accessors

    private func getAction(named name: String) -> RegisteredAction? {
        lock.lock()
        defer { lock.unlock() }
        return actions[name]
    }

    private func getActionNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions.keys.sorted()
    }

    private func listActions() -> MCPToolResult {
        lock.lock()
        let snapshot = actions
        lock.unlock()

        if snapshot.isEmpty {
            return .text("No actions registered. Use Apus.action(\"name\") { ... } to register actions the AI agent can execute.")
        }

        let list = snapshot.values.sorted(by: { $0.name < $1.name }).map { action in
            "  \(action.name): \(action.description)"
        }.joined(separator: "\n")

        return .text("Available actions (\(snapshot.count)):\n\(list)")
    }
}
