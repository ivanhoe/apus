import Foundation
import Swifter

/// Embedded HTTP server that exposes the MCP protocol over localhost.
final class MCPHTTPServer {
    private let server: HttpServer
    private let handler: MCPProtocolHandler
    private let security: SecurityMiddleware

    init(handler: MCPProtocolHandler, security: SecurityMiddleware) {
        self.server = HttpServer()
        self.handler = handler
        self.security = security
        setupRoutes()
    }

    /// Start the HTTP server on the given port and address.
    func start(port: UInt16, bindAddress: String) throws {
        server.listenAddressIPv4 = bindAddress
        try server.start(port, forceIPv4: true, priority: .utility)
    }

    /// Stop the HTTP server.
    func stop() {
        server.stop()
    }

    // MARK: - Route Setup

    private func setupRoutes() {
        // POST /mcp — JSON-RPC 2.0 handler
        server.POST["/mcp"] = { [weak self] request in
            guard let self = self else { return .internalServerError }

            // Security: validate origin
            guard self.security.validateOrigin(headers: request.headers) else {
                return .forbidden
            }
            let allowedOrigin = self.security.allowedOrigin(headers: request.headers)

            let bodyData = Data(request.body)

            // Bridge async handler to synchronous Swifter callback
            let responseBox = DataBox()
            let semaphore = DispatchSemaphore(value: 0)

            Task {
                let result = await self.handler.handleRequest(bodyData)
                responseBox.set(result)
                semaphore.signal()
            }
            semaphore.wait()
            let responseData = responseBox.get()

            // Notification (no response body)
            if responseData.isEmpty {
                return .raw(204, "No Content", nil, nil)
            }

            var headers = ["Content-Type": "application/json"]
            if let allowedOrigin {
                headers["Access-Control-Allow-Origin"] = allowedOrigin
                headers["Vary"] = "Origin"
            }

            return .raw(200, "OK", headers) { writer in
                try writer.write(responseData)
            }
        }

        // GET /mcp — SSE endpoint (server-to-client notifications)
        server.GET["/mcp"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            guard self.security.validateOrigin(headers: request.headers) else {
                return .forbidden
            }

            var headers = [
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
                "Connection": "keep-alive"
            ]
            if let allowedOrigin = self.security.allowedOrigin(headers: request.headers) {
                headers["Access-Control-Allow-Origin"] = allowedOrigin
                headers["Vary"] = "Origin"
            }

            return .raw(200, "OK", headers) { writer in
                let event = "event: open\ndata: {\"status\":\"connected\"}\n\n"
                try writer.write(Data(event.utf8))
            }
        }

        // OPTIONS /mcp — CORS preflight
        server["/mcp"] = { [weak self] request in
            // The generic subscript handles methods not matched by POST/GET
            if request.method == "OPTIONS" {
                guard let self = self else { return .internalServerError }
                guard self.security.validateOrigin(headers: request.headers) else {
                    return .forbidden
                }

                var headers = [
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization"
                ]
                if let allowedOrigin = self.security.allowedOrigin(headers: request.headers) {
                    headers["Access-Control-Allow-Origin"] = allowedOrigin
                    headers["Vary"] = "Origin"
                }
                return .raw(204, "No Content", headers, nil)
            }
            return .raw(405, "Method Not Allowed", nil, nil)
        }

        // GET / — Status page
        server["/"] = { [weak self] _ in
            let count = self?.handler.toolRegistry.toolCount ?? 0
            let status = """
            Apus MCP Server
            Status: Running
            Tools: \(count) registered
            Protocol: MCP \(MCPServerInfo.protocolVersion)
            Version: \(MCPServerInfo.version)
            """
            return .ok(.text(status))
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
