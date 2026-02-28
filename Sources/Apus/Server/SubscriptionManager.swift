import Foundation

/// Tracks per-connection channel subscriptions for WebSocket push notifications.
final class SubscriptionManager {
    /// A channel subscription with optional configuration (e.g. FPS, scale).
    struct Subscription {
        let channel: String
        let options: [String: Any]?
    }

    /// Called when the subscriber count for a channel changes.
    /// Use this to start/stop streamers (e.g. screenshot capture).
    var onSubscriptionChange: ((_ channel: String, _ subscriberCount: Int) -> Void)?

    /// connectionId → [channel → Subscription]
    private var subscriptions: [UUID: [String: Subscription]] = [:]
    private let lock = NSLock()

    /// Subscribe a connection to a channel.
    func subscribe(connectionId: UUID, channel: String, options: [String: Any]? = nil) {
        lock.lock()
        if subscriptions[connectionId] == nil {
            subscriptions[connectionId] = [:]
        }
        subscriptions[connectionId]?[channel] = Subscription(channel: channel, options: options)
        let count = subscriberCountLocked(for: channel)
        lock.unlock()
        onSubscriptionChange?(channel, count)
    }

    /// Unsubscribe a connection from a channel.
    func unsubscribe(connectionId: UUID, channel: String) {
        lock.lock()
        subscriptions[connectionId]?.removeValue(forKey: channel)
        let count = subscriberCountLocked(for: channel)
        lock.unlock()
        onSubscriptionChange?(channel, count)
    }

    /// Remove all subscriptions for a connection (e.g. on disconnect).
    func removeAll(for connectionId: UUID) {
        lock.lock()
        let channels = subscriptions[connectionId]?.keys.map { $0 } ?? []
        subscriptions.removeValue(forKey: connectionId)
        let counts = channels.map { ($0, subscriberCountLocked(for: $0)) }
        lock.unlock()
        for (channel, count) in counts {
            onSubscriptionChange?(channel, count)
        }
    }

    /// Connection IDs subscribed to a specific channel.
    func subscribers(for channel: String) -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        var result = Set<UUID>()
        for (connectionId, channels) in subscriptions {
            if channels[channel] != nil {
                result.insert(connectionId)
            }
        }
        return result
    }

    /// Subscription options for a specific connection and channel.
    func options(for connectionId: UUID, channel: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[connectionId]?[channel]?.options
    }

    /// Number of subscribers for a channel.
    func subscriberCount(for channel: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscriberCountLocked(for: channel)
    }

    /// All channels with at least one subscriber.
    var activeChannels: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var channels = Set<String>()
        for (_, channelMap) in subscriptions {
            for key in channelMap.keys {
                channels.insert(key)
            }
        }
        return channels
    }

    /// Status summary for diagnostics.
    func status() -> [String: Any] {
        lock.lock()
        let connectionCount = subscriptions.count
        var channelCounts: [String: Int] = [:]
        for (_, channelMap) in subscriptions {
            for key in channelMap.keys {
                channelCounts[key, default: 0] += 1
            }
        }
        lock.unlock()
        return [
            "connections": connectionCount,
            "channels": channelCounts
        ]
    }

    // MARK: - Private

    /// Must be called with lock held.
    private func subscriberCountLocked(for channel: String) -> Int {
        var count = 0
        for (_, channels) in subscriptions {
            if channels[channel] != nil {
                count += 1
            }
        }
        return count
    }
}
