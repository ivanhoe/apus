import Foundation

/// A log entry captured by the log system.
struct LogEntry {
    let timestamp: Date
    let level: String
    let message: String
    let source: String
}

/// MCP tool that captures and retrieves application logs.
/// Stores entries in a circular buffer and supports filtering.
final class LogCapture: MCPTool {
    var toolName: String { "get_logs" }
    var toolDescription: String {
        "Get recent application logs. Captures log entries from Apus.log() calls and optionally from stderr."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tail": [
                    "type": "integer",
                    "description": "Number of recent log entries to return (default: 100)"
                ],
                "grep": [
                    "type": "string",
                    "description": "Filter logs containing this string (case-insensitive)"
                ],
                "level": [
                    "type": "string",
                    "description": "Filter by log level",
                    "enum": ["debug", "info", "warning", "error"]
                ]
            ] as [String: Any]
        ]
    }

    private let buffer: CircularBuffer<LogEntry>
    private let dateFormatter: ISO8601DateFormatter

    init(bufferSize: Int = 1024) {
        self.buffer = CircularBuffer<LogEntry>(capacity: bufferSize)
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// Add a log entry to the buffer.
    func log(_ message: String, level: String = "info", source: String = "app") {
        buffer.append(LogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            source: source
        ))
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let tail = arguments["tail"] as? Int ?? 100
        let grep = arguments["grep"] as? String
        let level = arguments["level"] as? String

        var entries = buffer.tail(tail)

        if let grep = grep {
            entries = entries.filter {
                $0.message.localizedCaseInsensitiveContains(grep)
            }
        }

        if let level = level {
            entries = entries.filter { $0.level == level }
        }

        if entries.isEmpty {
            return .text("No log entries found matching the criteria. Total entries in buffer: \(buffer.totalCount)")
        }

        let formatted = entries.map { entry in
            let dateStr = dateFormatter.string(from: entry.timestamp)
            return "[\(dateStr)] [\(entry.level.uppercased())] [\(entry.source)] \(entry.message)"
        }.joined(separator: "\n")

        return .text("Log entries (\(entries.count) of \(buffer.totalCount) total):\n\n\(formatted)")
    }
}
