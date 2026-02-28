import Foundation

/// Bridges log and network events to WebSocket push notifications.
/// Listens for new entries from LogCapture and NetworkInterceptor,
/// formats them as JSON-RPC notifications, and broadcasts to subscribed connections.
final class EventBroadcaster {
    private let connectionManager: WebSocketConnectionManager
    private let subscriptionManager: SubscriptionManager
    private let timeFormatter: DateFormatter

    /// Well-known channel names.
    static let logsChannel = "logs"
    static let networkChannel = "network"
    static let screenshotsChannel = "screenshots"

    init(connectionManager: WebSocketConnectionManager, subscriptionManager: SubscriptionManager) {
        self.connectionManager = connectionManager
        self.subscriptionManager = subscriptionManager
        self.timeFormatter = DateFormatter()
        self.timeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    }

    /// Broadcast a new log entry to "logs" subscribers.
    func broadcastLogEntry(_ entry: LogEntry) {
        let subscribers = subscriptionManager.subscribers(for: Self.logsChannel)
        guard !subscribers.isEmpty else { return }

        let notification = buildNotification(
            method: "notifications/log",
            params: [
                "level": entry.level,
                "message": entry.message,
                "source": entry.source,
                "timestamp": timeFormatter.string(from: entry.timestamp)
            ]
        )
        guard let text = jsonString(notification) else { return }
        connectionManager.broadcastText(text, to: subscribers)
    }

    /// Broadcast a new network record to "network" subscribers.
    func broadcastNetworkRecord(_ record: NetworkRecord) {
        let subscribers = subscriptionManager.subscribers(for: Self.networkChannel)
        guard !subscribers.isEmpty else { return }

        var params: [String: Any] = [
            "id": record.id.uuidString,
            "method": record.request.httpMethod ?? "UNKNOWN",
            "url": record.request.url?.absoluteString ?? "unknown",
            "timestamp": timeFormatter.string(from: record.timestamp),
            "duration_ms": Int(record.duration * 1000)
        ]
        if let status = record.response?.statusCode {
            params["status"] = status
        }
        if let error = record.error {
            params["error"] = error.localizedDescription
        }

        let notification = buildNotification(
            method: "notifications/network",
            params: params
        )
        guard let text = jsonString(notification) else { return }
        connectionManager.broadcastText(text, to: subscribers)
    }

    /// Broadcast a screenshot frame (binary) to specific subscribers.
    func broadcastScreenshotFrame(_ frameData: Data, to subscribers: Set<UUID>) {
        connectionManager.broadcastBinary(frameData, to: subscribers)
    }

    // MARK: - Private

    private func buildNotification(method: String, params: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
    }

    private func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
