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
        "Get recent network request/response history including URLs, methods, status codes, headers, response bodies, and timing."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tail": [
                    "type": "integer",
                    "description": "Number of recent requests to return (default: 50)"
                ],
                "filter_url": [
                    "type": "string",
                    "description": "Filter requests whose URL contains this string"
                ],
                "filter_method": [
                    "type": "string",
                    "description": "Filter by HTTP method (GET, POST, PUT, DELETE, etc.)"
                ]
            ] as [String: Any]
        ]
    }

    private let buffer: CircularBuffer<NetworkRecord>
    private let dateFormatter: ISO8601DateFormatter

    init(bufferSize: Int = 256) {
        self.buffer = CircularBuffer<NetworkRecord>(capacity: bufferSize)
        self.dateFormatter = ISO8601DateFormatter()
    }

    /// Record a network request/response.
    func record(_ record: NetworkRecord) {
        buffer.append(record)
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let tail = arguments["tail"] as? Int ?? 50
        let filterUrl = arguments["filter_url"] as? String
        let filterMethod = arguments["filter_method"] as? String

        var records = buffer.tail(tail)

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

        if records.isEmpty {
            return .text("No network requests recorded matching the criteria. Total recorded: \(buffer.totalCount)")
        }

        let formatted = records.map { record in
            formatRecord(record)
        }.joined(separator: "\n---\n")

        return .text("Network History (\(records.count) of \(buffer.totalCount) total):\n\n\(formatted)")
    }

    private func formatRecord(_ record: NetworkRecord) -> String {
        let method = record.request.httpMethod ?? "UNKNOWN"
        let url = record.request.url?.absoluteString ?? "unknown"
        let status = record.response?.statusCode.description ?? "no response"
        let duration = String(format: "%.1fms", record.duration * 1000)
        let dateStr = dateFormatter.string(from: record.timestamp)

        var entry = "[\(dateStr)] \(method) \(url)\n"
        entry += "  Status: \(status) | Duration: \(duration)\n"

        // Request headers
        if let headers = record.request.allHTTPHeaderFields, !headers.isEmpty {
            let headerStr = headers.map { "    \($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            entry += "  Request Headers:\n\(headerStr)\n"
        }

        // Request body
        if let body = record.request.httpBody, !body.isEmpty {
            if let bodyStr = String(data: body.prefix(500), encoding: .utf8) {
                entry += "  Request Body: \(bodyStr)"
                if body.count > 500 { entry += "... (\(body.count) bytes)" }
                entry += "\n"
            } else {
                entry += "  Request Body: <binary, \(body.count) bytes>\n"
            }
        }

        // Error
        if let error = record.error {
            entry += "  Error: \(error.localizedDescription)\n"
        }

        // Response body
        if let body = record.responseBody, !body.isEmpty {
            if let bodyStr = String(data: body.prefix(1000), encoding: .utf8) {
                entry += "  Response Body: \(bodyStr)"
                if body.count > 1000 { entry += "... (\(body.count) bytes total)" }
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
