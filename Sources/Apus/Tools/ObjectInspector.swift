import Foundation

/// MCP tool that inspects registered objects using Swift Mirror reflection.
final class ObjectInspector: MCPTool {
    var toolName: String { "inspect_object" }
    var toolDescription: String {
        "Inspect a registered object using Swift Mirror reflection. Objects must be registered via Apus.register(). Call without 'id' to list all registered objects."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "id": [
                    "type": "string",
                    "description": "The registered object identifier. Omit to list all registered objects."
                ],
                "depth": [
                    "type": "integer",
                    "description": "Reflection depth for nested properties (default: 3)"
                ]
            ] as [String: Any]
        ]
    }

    private var registeredObjects: [String: () -> Any?] = [:]
    private let lock = NSLock()

    /// Register an object for inspection. For reference types, stores a weak reference.
    func register(_ object: Any, id: String) {
        lock.lock()
        defer { lock.unlock() }

        if type(of: object) is AnyClass {
            // Reference type: store weak reference
            let ref = object as AnyObject
            registeredObjects[id] = { [weak ref] in ref }
        } else {
            // Value type: store a copy (caller should re-register on changes)
            let copy = object
            registeredObjects[id] = { copy }
        }
    }

    /// Register a provider closure that returns the current value of an object.
    /// Useful for value types that change over time.
    func register(id: String, provider: @escaping () -> Any?) {
        lock.lock()
        defer { lock.unlock() }
        registeredObjects[id] = provider
    }

    /// Unregister an object by ID.
    func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        registeredObjects.removeValue(forKey: id)
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let id = arguments["id"] as? String else {
            return listRegisteredObjects()
        }

        let provider = getProvider(for: id)

        guard let provider = provider, let object = provider() else {
            return .error("Object '\(id)' not found or has been deallocated.")
        }

        let depth = arguments["depth"] as? Int ?? 3
        let inspection = MirrorHelper.inspect(object, depth: depth)
        let json = JSONHelper.serializeToString(inspection)

        return .text("Object '\(id)' (\(String(describing: type(of: object)))):\n\n\(json)")
    }

    /// Thread-safe provider lookup (avoids NSLock in async context).
    private func getProvider(for id: String) -> (() -> Any?)? {
        lock.lock()
        defer { lock.unlock() }
        return registeredObjects[id]
    }

    private func listRegisteredObjects() -> MCPToolResult {
        lock.lock()
        let entries = registeredObjects
        lock.unlock()

        if entries.isEmpty {
            return .text("No objects registered. Use Apus.shared.register(object, id: \"myId\") to register objects for inspection.")
        }

        let list = entries.keys.sorted().map { id -> String in
            let obj = entries[id]?()
            let typeName = obj.map { String(describing: type(of: $0)) } ?? "<deallocated>"
            return "  \(id): \(typeName)"
        }.joined(separator: "\n")

        return .text("Registered objects (\(entries.count)):\n\(list)")
    }
}
