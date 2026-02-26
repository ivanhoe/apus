import Foundation

/// MCP tool that returns full details of a single network request by ID.
/// Complements `get_network_history` (list) with a detail view that includes
/// complete headers, untruncated bodies, and timing information.
final class NetworkRequestDetail: MCPTool {
    var toolName: String { "get_network_request_detail" }
    var toolDescription: String {
        "Get full details of a network request by ID: complete headers, bodies, timing."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "request_id": [
                    "type": "string",
                    "description": "UUID of the request (from get_network_history output)"
                ],
                "max_body_size": [
                    "type": "integer",
                    "description": "Max bytes to return per body (default: 51200 = 50KB). Use 0 for unlimited."
                ]
            ] as [String: Any],
            "required": ["request_id"]
        ]
    }

    weak var interceptor: NetworkInterceptor?
    private let dateFormatter: DateFormatter

    init(interceptor: NetworkInterceptor) {
        self.interceptor = interceptor
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let interceptor = interceptor else {
            return .error("Network interceptor is not available.")
        }

        guard let requestIdStr = arguments["request_id"] as? String else {
            return .error("Missing required parameter: request_id")
        }

        guard let requestId = UUID(uuidString: requestIdStr) else {
            return .error("Invalid UUID format: \(requestIdStr)")
        }

        let maxBodySize = arguments["max_body_size"] as? Int ?? 51200

        guard maxBodySize >= 0 else {
            return .error("Invalid value for max_body_size: \(maxBodySize). Must be >= 0 (use 0 for unlimited).")
        }

        guard let record = interceptor.findRecord(id: requestId) else {
            return .error("Request not found: \(requestIdStr). The record may have been evicted from the buffer.")
        }

        return .text(formatDetail(record, maxBodySize: maxBodySize))
    }

    private func formatDetail(_ record: NetworkRecord, maxBodySize: Int) -> String {
        var sections: [String] = []

        // Request line
        let method = record.request.httpMethod ?? "UNKNOWN"
        let url = record.request.url?.absoluteString ?? "unknown"
        sections.append("# \(method) \(url)")

        // Timing
        let timestamp = self.dateFormatter.string(from: record.timestamp)
        let duration = String(format: "%.1fms", record.duration * 1000)
        sections.append("Timestamp: \(timestamp)\nDuration: \(duration)")

        // Request headers
        if let headers = record.request.allHTTPHeaderFields, !headers.isEmpty {
            let headerLines = headers.sorted { $0.key < $1.key }
                .map { "  \($0.key): \($0.value)" }
                .joined(separator: "\n")
            sections.append("## Request Headers\n\(headerLines)")
        } else {
            sections.append("## Request Headers\n  (none)")
        }

        // Request body
        if let body = record.request.httpBody, !body.isEmpty {
            sections.append("## Request Body\n\(formatBody(body, maxSize: maxBodySize))")
        }

        // Response status
        if let response = record.response {
            sections.append("## Response\nStatus: \(response.statusCode)")

            // Response headers
            let responseHeaders = response.allHeaderFields
            if !responseHeaders.isEmpty {
                let headerLines = responseHeaders
                    .map { "  \($0.key): \($0.value)" }
                    .sorted()
                    .joined(separator: "\n")
                sections.append("## Response Headers\n\(headerLines)")
            }
        } else {
            sections.append("## Response\nStatus: no response")
        }

        // Error
        if let error = record.error {
            sections.append("## Error\n\(error.localizedDescription)")
        }

        // Response body
        if let body = record.responseBody, !body.isEmpty {
            sections.append("## Response Body\n\(formatBody(body, maxSize: maxBodySize))")
        }

        return sections.joined(separator: "\n\n")
    }

    private func formatBody(_ data: Data, maxSize: Int) -> String {
        let totalSize = data.count
        let effectiveData = (maxSize > 0 && totalSize > maxSize) ? data.prefix(maxSize) : data

        if let text = String(data: effectiveData, encoding: .utf8) {
            var result = text
            if maxSize > 0 && totalSize > maxSize {
                result += "\n... truncated (\(totalSize) bytes total, showing \(maxSize))"
            }
            result += "\n(encoding: utf-8, size: \(totalSize) bytes)"
            return result
        } else {
            let base64 = effectiveData.base64EncodedString()
            var result = base64
            if maxSize > 0 && totalSize > maxSize {
                result += "\n... truncated (\(totalSize) bytes total, showing \(maxSize))"
            }
            result += "\n(encoding: base64, size: \(totalSize) bytes)"
            return result
        }
    }
}
