import Foundation
import Network

/// WebSocket server for persistent bidirectional MCP communication.
/// Runs on a separate port from the HTTP server (default: 9848).
/// Uses `NWProtocolWebSocket` from Network.framework — zero external dependencies.
final class WebSocketServer {
    private var listener: NWListener?
    let connectionManager = WebSocketConnectionManager()
    private let handler: MCPProtocolHandler
    private let queue = DispatchQueue(label: "com.apus.wsserver", qos: .utility)

    /// Subscription manager for channel-based push notifications.
    var subscriptionManager: SubscriptionManager?

    init(handler: MCPProtocolHandler) {
        self.handler = handler
    }

    /// Start the WebSocket server on the given port and bind address.
    func start(port: UInt16, bindAddress: String) throws {
        let params = NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true

        if bindAddress == "127.0.0.1" || bindAddress == "localhost" {
            params.requiredInterfaceType = .loopback
        }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }

        let newListener = try NWListener(using: params, on: nwPort)

        let semaphore = DispatchSemaphore(value: 0)
        var startError: NWError?

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] nwConnection in
            self?.handleNewConnection(nwConnection)
        }

        newListener.start(queue: queue)
        semaphore.wait()

        if let error = startError {
            newListener.cancel()
            throw error
        }

        self.listener = newListener
    }

    /// Stop the WebSocket server and disconnect all clients.
    func stop() {
        connectionManager.disconnectAll()
        listener?.cancel()
        listener = nil
    }

    /// Whether the server is currently listening.
    var isRunning: Bool {
        listener != nil
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ nwConnection: NWConnection) {
        let connection = WebSocketConnection(connection: nwConnection, queue: queue)
        connection.delegate = self

        guard connectionManager.add(connection) else {
            // Max connections reached — reject
            nwConnection.cancel()
            return
        }

        connection.start()
    }
}

// MARK: - WebSocketConnectionDelegate

extension WebSocketServer: WebSocketConnectionDelegate {
    func connection(_ connection: WebSocketConnection, didReceiveText text: String) {
        let data = Data(text.utf8)

        // Check for subscribe/unsubscribe before forwarding to MCP handler
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let method = json["method"] as? String,
           (method == MCPMethod.subscribe || method == MCPMethod.unsubscribe) {
            handleSubscription(method: method, json: json, connection: connection)
            return
        }

        // Standard MCP request — forward to protocol handler
        Task {
            let response = await self.handler.handleRequest(data)
            guard !response.isEmpty else { return }
            if let responseText = String(data: response, encoding: .utf8) {
                connection.sendText(responseText)
            }
        }
    }

    func connection(_ connection: WebSocketConnection, didReceiveBinary data: Data) {
        // Binary messages from client not expected
    }

    func connectionDidDisconnect(_ connection: WebSocketConnection) {
        subscriptionManager?.removeAll(for: connection.id)
        connectionManager.remove(connection.id)
    }

    // MARK: - Subscription Handling

    private func handleSubscription(method: String, json: [String: Any], connection: WebSocketConnection) {
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]
        let channels = params["channels"] as? [String] ?? []
        let options = params["options"] as? [String: Any]

        guard let subscriptionManager else {
            let response = JSONRPCResponse.error(
                id: id,
                code: MCPErrorCode.internalError,
                message: "Subscriptions not available"
            )
            if let text = String(data: response, encoding: .utf8) {
                connection.sendText(text)
            }
            return
        }

        if method == MCPMethod.subscribe {
            for channel in channels {
                subscriptionManager.subscribe(
                    connectionId: connection.id,
                    channel: channel,
                    options: options
                )
            }
            let response = JSONRPCResponse.success(id: id, result: ["subscribed": channels])
            if let text = String(data: response, encoding: .utf8) {
                connection.sendText(text)
            }
        } else {
            for channel in channels {
                subscriptionManager.unsubscribe(connectionId: connection.id, channel: channel)
            }
            let response = JSONRPCResponse.success(id: id, result: ["unsubscribed": channels])
            if let text = String(data: response, encoding: .utf8) {
                connection.sendText(text)
            }
        }
    }
}
