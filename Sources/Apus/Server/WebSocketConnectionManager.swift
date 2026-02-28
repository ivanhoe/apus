import Foundation

/// Thread-safe registry of active WebSocket connections.
/// Provides broadcast primitives and enforces a connection limit.
final class WebSocketConnectionManager {
    private var connections: [UUID: WebSocketConnection] = [:]
    private let lock = NSLock()

    /// Maximum number of simultaneous WebSocket connections.
    static let maxConnections = 5

    /// Add a connection to the registry.
    /// Returns `false` and rejects the connection if the limit is reached.
    @discardableResult
    func add(_ connection: WebSocketConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if connections.count >= Self.maxConnections {
            return false
        }
        connections[connection.id] = connection
        return true
    }

    /// Remove a connection by ID.
    func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        connections.removeValue(forKey: id)
    }

    /// Get a connection by ID.
    func connection(for id: UUID) -> WebSocketConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections[id]
    }

    /// Broadcast a text notification to specific connections.
    func broadcastText(_ text: String, to connectionIds: Set<UUID>) {
        lock.lock()
        let targets = connectionIds.compactMap { connections[$0] }
        lock.unlock()
        for connection in targets {
            connection.sendNotification(text)
        }
    }

    /// Broadcast binary data to specific connections.
    func broadcastBinary(_ data: Data, to connectionIds: Set<UUID>) {
        lock.lock()
        let targets = connectionIds.compactMap { connections[$0] }
        lock.unlock()
        for connection in targets {
            connection.sendBinary(data)
        }
    }

    /// Disconnect all connections and clear the registry.
    func disconnectAll() {
        lock.lock()
        let all = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        for connection in all {
            connection.cancel()
        }
    }

    /// Number of active connections.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// All active connection IDs.
    var connectionIds: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(connections.keys)
    }

    /// Status summary for diagnostics.
    func status() -> [String: Any] {
        lock.lock()
        let count = connections.count
        let ids = connections.keys.map { $0.uuidString }
        lock.unlock()
        return [
            "activeConnections": count,
            "connectionIds": ids
        ]
    }
}
