import Foundation
import Network

/// Embedded HTTP server that exposes the MCP protocol over localhost.
/// Uses Network.framework (NWListener) — zero external dependencies.
final class MCPHTTPServer {
    private var listener: NWListener?
    private let handler: MCPProtocolHandler
    private let security: SecurityMiddleware
    private let queue = DispatchQueue(label: "com.apus.httpserver", qos: .utility)

    /// Creates a new HTTP server backed by the given protocol handler and security middleware.
    /// - Parameters:
    ///   - handler: The MCP JSON-RPC handler that processes incoming requests.
    ///   - security: Middleware that validates request origins and enforces access rules.
    init(handler: MCPProtocolHandler, security: SecurityMiddleware) {
        self.handler = handler
        self.security = security
    }

    /// Start the HTTP server on the given port and address.
    func start(port: UInt16, bindAddress: String) throws {
        let params = NWParameters.tcp
        if bindAddress == "127.0.0.1" || bindAddress == "localhost" {
            params.requiredInterfaceType = .loopback
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let newListener = try NWListener(using: params, on: nwPort)

        // Block until the listener is ready or fails, so callers get
        // a synchronous error when the port is already in use.
        // Intentional: the wait is ~1-5ms for localhost binding and keeps start()
        // synchronous, which allows Apus.shared.start() to report port conflicts
        // immediately. Converting to async would break the public API contract.
        let semaphore = DispatchSemaphore(value: 0)
        var startError: NWError?

        newListener.stateUpdateHandler = { (state: NWListener.State) in
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

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.start(queue: queue)
        semaphore.wait()

        if let error = startError {
            newListener.cancel()
            throw error
        }

        self.listener = newListener
    }

    /// Stop the HTTP server.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            if let parsed = HTTPRequestParser.parse(accumulated) {
                self.route(parsed.request, on: connection, remainingBuffer: parsed.remaining)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: accumulated)
            }
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection, remainingBuffer: Data) {
        switch (request.method, request.path) {
        case ("POST", "/mcp"):
            handleMCPPost(request, on: connection, remainingBuffer: remainingBuffer)
        case ("GET", "/mcp"):
            handleMCPGet(request, on: connection, remainingBuffer: remainingBuffer)
        case ("OPTIONS", "/mcp"):
            handleMCPOptions(request, on: connection, remainingBuffer: remainingBuffer)
        case ("GET", "/"):
            handleStatus(on: connection, remainingBuffer: remainingBuffer)
        default:
            send(.status(405, "Method Not Allowed"), on: connection, nextBuffer: remainingBuffer)
        }
    }

    // MARK: - Route Handlers

    private func handleMCPPost(_ request: HTTPRequest, on connection: NWConnection, remainingBuffer: Data) {
        guard security.validateOrigin(headers: request.headers) else {
            send(.status(403, "Forbidden"), on: connection, nextBuffer: remainingBuffer)
            return
        }

        let allowedOrigin = security.allowedOrigin(headers: request.headers)
        let handler = self.handler // capture strong ref before entering Task

        Task { [weak self] in
            let result = await handler.handleRequest(request.body)

            guard let self else {
                connection.cancel()
                return
            }

            if result.isEmpty {
                self.send(.status(204, "No Content"), on: connection, nextBuffer: remainingBuffer)
                return
            }

            var headers = ["Content-Type": "application/json"]
            if let origin = allowedOrigin {
                headers["Access-Control-Allow-Origin"] = origin
                headers["Vary"] = "Origin"
            }

            self.send(
                HTTPResponse(status: 200, reason: "OK", headers: headers, body: result),
                on: connection,
                nextBuffer: remainingBuffer
            )
        }
    }

    private func handleMCPGet(_ request: HTTPRequest, on connection: NWConnection, remainingBuffer: Data) {
        guard security.validateOrigin(headers: request.headers) else {
            send(.status(403, "Forbidden"), on: connection, nextBuffer: remainingBuffer)
            return
        }

        var headers: [String: String] = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
        ]
        if let origin = security.allowedOrigin(headers: request.headers) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        }

        let event = "event: open\ndata: {\"status\":\"connected\"}\n\n"
        send(
            HTTPResponse(status: 200, reason: "OK", headers: headers, body: Data(event.utf8)),
            on: connection,
            nextBuffer: remainingBuffer
        )
    }

    private func handleMCPOptions(_ request: HTTPRequest, on connection: NWConnection, remainingBuffer: Data) {
        guard security.validateOrigin(headers: request.headers) else {
            send(.status(403, "Forbidden"), on: connection, nextBuffer: remainingBuffer)
            return
        }

        var headers: [String: String] = [
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Authorization"
        ]
        if let origin = security.allowedOrigin(headers: request.headers) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        }

        send(HTTPResponse(status: 204, reason: "No Content", headers: headers), on: connection, nextBuffer: remainingBuffer)
    }

    private func handleStatus(on connection: NWConnection, remainingBuffer: Data) {
        let count = handler.toolRegistry.toolCount
        let body = """
        Apus MCP Server
        Status: Running
        Tools: \(count) registered
        Protocol: MCP \(MCPServerInfo.protocolVersion)
        Version: \(MCPServerInfo.version)
        """
        send(
            HTTPResponse(status: 200, reason: "OK", headers: ["Content-Type": "text/plain"], body: Data(body.utf8)),
            on: connection,
            nextBuffer: remainingBuffer
        )
    }

    // MARK: - Send

    private func send(_ response: HTTPResponse, on connection: NWConnection, nextBuffer: Data = Data()) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] error in
            if error != nil {
                connection.cancel()
                return
            }
            if response.shouldCloseConnection {
                connection.cancel()
                return
            }
            if response.isEventStream {
                return
            }
            self?.receiveRequest(on: connection, buffer: nextBuffer)
        })
    }
}

// MARK: - HTTP Types

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse {
    let status: Int
    let reason: String
    var headers: [String: String] = [:]
    var body = Data()

    static func status(_ code: Int, _ reason: String) -> HTTPResponse {
        HTTPResponse(status: code, reason: reason)
    }

    private func value(forHeader name: String, in source: [String: String]? = nil) -> String? {
        let headersToSearch = source ?? headers
        return headersToSearch.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func containsHeader(_ name: String, in source: [String: String]) -> Bool {
        source.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    var shouldCloseConnection: Bool {
        value(forHeader: "Connection")?.caseInsensitiveCompare("keep-alive") != .orderedSame
    }

    var isEventStream: Bool {
        value(forHeader: "Content-Type")?.localizedCaseInsensitiveContains("text/event-stream") == true
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var allHeaders = headers
        if !containsHeader("Connection", in: allHeaders) {
            allHeaders["Connection"] = "close"
        }
        if !body.isEmpty {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - HTTP Parser

private enum HTTPRequestParser {
    static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    struct ParsedRequest {
        let request: HTTPRequest
        let remaining: Data
    }

    static func parse(_ data: Data) -> ParsedRequest? {
        guard let range = data.range(of: headerTerminator) else { return nil }

        guard let headerString = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = range.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        if contentLength > 0 {
            let available = data.count - bodyStart
            guard available >= contentLength else { return nil }
            let bodyEnd = bodyStart + contentLength
            let request = HTTPRequest(
                method: method,
                path: path,
                headers: headers,
                body: Data(data[bodyStart..<bodyEnd])
            )
            let remaining = Data(data[bodyEnd...])
            return ParsedRequest(request: request, remaining: remaining)
        }

        let request = HTTPRequest(method: method, path: path, headers: headers, body: Data())
        let remaining = Data(data[bodyStart...])
        return ParsedRequest(request: request, remaining: remaining)
    }
}
