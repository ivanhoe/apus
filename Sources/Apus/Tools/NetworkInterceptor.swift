import Foundation

/// A recorded network request/response pair.
struct NetworkRecord {
    let id: UUID
    let timestamp: Date
    let request: URLRequest
    let response: HTTPURLResponse?
    let responseBody: Data?
    let error: Error?
    let duration: TimeInterval
}

/// MCP tool that captures and retrieves network request history.
final class NetworkInterceptor: MCPTool {
    var toolName: String { "get_network_history" }
    var toolDescription: String {
        "Network history: URLs, status, timing. Headers hidden by default."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tail": [
                    "type": "integer",
                    "description": "Number of recent requests to return (default: 20)"
                ],
                "filter_url": [
                    "type": "string",
                    "description": "Filter requests whose URL contains this string"
                ],
                "filter_method": [
                    "type": "string",
                    "description": "Filter by HTTP method (GET, POST, PUT, DELETE, etc.)"
                ],
                "include_headers": [
                    "type": "boolean",
                    "description": "Include request/response headers (default: false)"
                ],
                "since": [
                    "type": "integer",
                    "description": "Watermark from previous call. Returns only new requests since that point."
                ]
            ] as [String: Any]
        ]
    }

    private let buffer: CircularBuffer<NetworkRecord>
    private let timeFormatter: DateFormatter

    /// Called when a new network record is completed. Used by EventBroadcaster for push notifications.
    var onNewRecord: ((NetworkRecord) -> Void)?

    init(bufferSize: Int = 256) {
        self.buffer = CircularBuffer<NetworkRecord>(capacity: bufferSize)
        self.timeFormatter = DateFormatter()
        self.timeFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    /// Record a network request/response.
    func record(_ record: NetworkRecord) {
        buffer.append(record)
        onNewRecord?(record)
    }

    /// Find a recorded request by its UUID.
    func findRecord(id: UUID) -> NetworkRecord? {
        buffer.allElements().first { $0.id == id }
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let tail = arguments["tail"] as? Int ?? 20
        let filterUrl = arguments["filter_url"] as? String
        let filterMethod = arguments["filter_method"] as? String
        let includeHeaders = arguments["include_headers"] as? Bool ?? false
        let since = arguments["since"] as? Int

        var records: [NetworkRecord]
        if let since = since {
            records = buffer.tailSince(since)
        } else {
            records = buffer.tail(tail)
        }

        if let filterUrl = filterUrl {
            records = records.filter {
                $0.request.url?.absoluteString.localizedCaseInsensitiveContains(filterUrl) ?? false
            }
        }

        if let filterMethod = filterMethod {
            records = records.filter {
                $0.request.httpMethod?.uppercased() == filterMethod.uppercased()
            }
        }

        let watermark = buffer.totalAppended

        if records.isEmpty {
            if since != nil {
                return .text("No new network requests. (watermark: \(watermark))")
            }
            return .text("No network requests recorded matching the criteria. Total recorded: \(buffer.totalCount)")
        }

        let formatted = records.map { record in
            formatRecord(record, includeHeaders: includeHeaders)
        }.joined(separator: "\n---\n")

        return .text("Network History (\(records.count) of \(buffer.totalCount) total, watermark: \(watermark)):\n\n\(formatted)")
    }

    private func formatRecord(_ record: NetworkRecord, includeHeaders: Bool) -> String {
        let method = record.request.httpMethod ?? "UNKNOWN"
        let url = record.request.url?.absoluteString ?? "unknown"
        let status = record.response?.statusCode.description ?? "no response"
        let duration = String(format: "%.1fms", record.duration * 1000)
        let dateStr = timeFormatter.string(from: record.timestamp)

        var entry = "[\(dateStr)] \(method) \(url) (id: \(record.id.uuidString))\n"
        entry += "  Status: \(status) | Duration: \(duration)\n"

        // Request headers (only when explicitly requested)
        if includeHeaders, let headers = record.request.allHTTPHeaderFields, !headers.isEmpty {
            let headerStr = headers.map { "    \($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            entry += "  Request Headers:\n\(headerStr)\n"
        }

        // Request body (truncated to 100 bytes)
        if let body = record.request.httpBody, !body.isEmpty {
            if let bodyStr = String(data: body.prefix(100), encoding: .utf8) {
                entry += "  Request Body: \(bodyStr)"
                if body.count > 100 { entry += "... (\(body.count) bytes)" }
                entry += "\n"
            } else {
                entry += "  Request Body: <binary, \(body.count) bytes>\n"
            }
        }

        // Error
        if let error = record.error {
            entry += "  Error: \(error.localizedDescription)\n"
        }

        // Response body (truncated to 200 bytes)
        if let body = record.responseBody, !body.isEmpty {
            if let bodyStr = String(data: body.prefix(200), encoding: .utf8) {
                entry += "  Response Body: \(bodyStr)"
                if body.count > 200 { entry += "... (\(body.count) bytes total)" }
                entry += "\n"
            } else {
                entry += "  Response Body: <binary, \(body.count) bytes>\n"
            }
        }

        return entry
    }
}

// MARK: - URLProtocol Interceptor

/// URLProtocol subclass that intercepts network requests and records them.
/// Register with URLProtocol.registerClass() or add to URLSessionConfiguration.protocolClasses.
final class ApusURLProtocol: URLProtocol {
    static weak var interceptor: NetworkInterceptor?

    private static let handledKey = "ApusHandled"
    private var startTime: Date?
    private var accumulatedData = Data()
    private var httpResponse: HTTPURLResponse?
    private var dataTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool {
        // Don't intercept our own MCP server requests
        if let port = request.url?.port, port == 9847 {
            return false
        }
        // Don't re-intercept already handled requests
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        startTime = Date()

        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: mutableRequest as URLRequest)
        self.dataTask = task
        task.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }
}

extension ApusURLProtocol: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        httpResponse = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        accumulatedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0

        // Record the network call
        let record = NetworkRecord(
            id: UUID(),
            timestamp: startTime ?? Date(),
            request: request,
            response: httpResponse,
            responseBody: accumulatedData.isEmpty ? nil : accumulatedData,
            error: error,
            duration: duration
        )
        Self.interceptor?.record(record)

        if let error = error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
