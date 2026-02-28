import Foundation
import Network

/// Delegate protocol for WebSocket connection events.
protocol WebSocketConnectionDelegate: AnyObject {
    /// Called when a text message is received.
    func connection(_ connection: WebSocketConnection, didReceiveText text: String)
    /// Called when a binary message is received.
    func connection(_ connection: WebSocketConnection, didReceiveBinary data: Data)
    /// Called when the connection is disconnected.
    func connectionDidDisconnect(_ connection: WebSocketConnection)
}

/// Wraps a single NWConnection upgraded to WebSocket.
/// Provides receive loop, send text/binary, heartbeat, and backpressure.
final class WebSocketConnection {
    /// Unique identifier for this connection.
    let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    weak var delegate: WebSocketConnectionDelegate?

    // Heartbeat & idle timeout
    private var lastActivityTime: Date = Date()
    private var heartbeatTimer: DispatchSourceTimer?
    static let heartbeatInterval: TimeInterval = 30
    static let idleTimeout: TimeInterval = 60

    // Backpressure: drop notifications when the send queue is too deep
    private var pendingNotificationCount = 0
    private let pendingLock = NSLock()
    static let maxPendingNotifications = 100

    private var didNotifyDisconnect = false
    private let disconnectLock = NSLock()

    init(id: UUID = UUID(), connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    /// Start the connection and begin receiving messages.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.notifyDisconnectedOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNextMessage()
        startHeartbeat()
    }

    /// Send a text message (JSON-RPC response).
    func sendText(_ text: String) {
        let data = Data(text.utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "text",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    /// Send a notification text message, subject to backpressure.
    /// Returns `false` if the notification was dropped because the send queue is full.
    @discardableResult
    func sendNotification(_ text: String) -> Bool {
        pendingLock.lock()
        if pendingNotificationCount >= Self.maxPendingNotifications {
            pendingLock.unlock()
            return false
        }
        pendingNotificationCount += 1
        pendingLock.unlock()

        let data = Data(text.utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "notification",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.decrementPending()
            }
        )
        return true
    }

    /// Send a binary message (e.g. screenshot frame).
    func sendBinary(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(
            identifier: "binary",
            metadata: [metadata]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    /// Cancel the connection.
    func cancel() {
        notifyDisconnectedOnce()
        connection.cancel()
    }

    // MARK: - Receive Loop

    private func receiveNextMessage() {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self else { return }

            if error != nil {
                self.notifyDisconnectedOnce()
                return
            }

            self.lastActivityTime = Date()

            guard let metadata = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata else {
                self.receiveNextMessage()
                return
            }

            switch metadata.opcode {
            case .text:
                if let data = content, let text = String(data: data, encoding: .utf8) {
                    self.delegate?.connection(self, didReceiveText: text)
                }
            case .binary:
                if let data = content {
                    self.delegate?.connection(self, didReceiveBinary: data)
                }
            case .close:
                self.notifyDisconnectedOnce()
                return
            default:
                break
            }

            self.receiveNextMessage()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.heartbeatInterval,
            repeating: Self.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat()
        }
        timer.resume()
        self.heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func checkHeartbeat() {
        let idle = Date().timeIntervalSince(lastActivityTime)
        if idle > Self.idleTimeout {
            cancel()
            return
        }
        let ping = #"{"jsonrpc":"2.0","method":"ping"}"#
        sendText(ping)
    }

    private func decrementPending() {
        pendingLock.lock()
        pendingNotificationCount = max(0, pendingNotificationCount - 1)
        pendingLock.unlock()
    }

    private func notifyDisconnectedOnce() {
        disconnectLock.lock()
        if didNotifyDisconnect {
            disconnectLock.unlock()
            return
        }
        didNotifyDisconnect = true
        disconnectLock.unlock()

        stopHeartbeat()
        delegate?.connectionDidDisconnect(self)
    }
}
