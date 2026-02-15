import Foundation
import OSLog

/// A log entry captured by the log system.
struct LogEntry {
    let timestamp: Date
    let level: String
    let message: String
    let source: String
}

/// MCP tool that captures and retrieves application logs.
/// Supports three capture sources:
/// - Manual: Apus.shared.log() calls
/// - OSLog: System logs via OSLogStore (iOS 15+, zero-code)
/// - stderr: print() and NSLog() output (zero-code)
final class LogCapture: MCPTool {
    var toolName: String { "get_logs" }
    var toolDescription: String {
        "App logs (Apus.log, os_log, print). Filter: level, grep, source."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "tail": [
                    "type": "integer",
                    "description": "Number of recent log entries to return (default: 50)"
                ],
                "grep": [
                    "type": "string",
                    "description": "Filter logs containing this string (case-insensitive)"
                ],
                "level": [
                    "type": "string",
                    "description": "Filter by log level",
                    "enum": ["debug", "info", "warning", "error"]
                ],
                "source": [
                    "type": "string",
                    "description": "Filter by source (e.g. 'stderr', 'com.myapp/networking', or a custom source)"
                ]
            ] as [String: Any]
        ]
    }

    private let buffer: CircularBuffer<LogEntry>
    private let timeFormatter: DateFormatter

    private var osLogReader: AnyObject?
    private var stderrCapture: StderrCapture?
    private var osLogTimer: Timer?

    init(bufferSize: Int = 1024) {
        self.buffer = CircularBuffer<LogEntry>(capacity: bufferSize)
        self.timeFormatter = DateFormatter()
        self.timeFormatter.dateFormat = "HH:mm:ss.SSS"
    }

    // MARK: - Manual logging

    /// Add a log entry to the buffer.
    func log(_ message: String, level: String = "info", source: String = "app") {
        buffer.append(LogEntry(
            timestamp: Date(),
            level: level,
            message: message,
            source: source
        ))
    }

    // MARK: - System log capture

    /// Start capturing system logs (OSLog + stderr).
    /// Called automatically by Apus.start() when captureSystemLogs is true.
    func startSystemCapture() {
        startOSLogCapture()
        startStderrCapture()
    }

    /// Stop all system log capture.
    func stopSystemCapture() {
        osLogTimer?.invalidate()
        osLogTimer = nil
        osLogReader = nil
        stderrCapture?.stop()
        stderrCapture = nil
    }

    private func startOSLogCapture() {
        guard #available(iOS 15.0, macOS 12.0, *) else { return }

        let reader = OSLogReader()
        self.osLogReader = reader

        // Poll for new OSLog entries every 2 seconds
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self, weak reader] _ in
            guard let reader = reader else { return }
            let entries = reader.fetchNewEntries()
            for entry in entries {
                // Skip Apus's own logs to avoid noise
                guard !entry.source.contains("Apus") else { continue }
                self?.buffer.append(entry)
            }
        }
        self.osLogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startStderrCapture() {
        let capture = StderrCapture { [weak self] line in
            // Skip Apus's own output
            guard !line.hasPrefix("[Apus]") else { return }

            self?.buffer.append(LogEntry(
                timestamp: Date(),
                level: "info",
                message: line,
                source: "stderr"
            ))
        }
        self.stderrCapture = capture
        capture.start()
    }

    // MARK: - Tool execution

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        // Before returning results, pull latest OSLog entries
        if #available(iOS 15.0, macOS 12.0, *) {
            if let reader = osLogReader as? OSLogReader {
                let entries = reader.fetchNewEntries()
                for entry in entries {
                    guard !entry.source.contains("Apus") else { continue }
                    buffer.append(entry)
                }
            }
        }

        let tail = arguments["tail"] as? Int ?? 50
        let grep = arguments["grep"] as? String
        let level = arguments["level"] as? String
        let source = arguments["source"] as? String

        var entries = buffer.tail(tail * 2) // fetch extra to account for filtering

        if let grep = grep {
            entries = entries.filter {
                $0.message.localizedCaseInsensitiveContains(grep)
            }
        }

        if let level = level {
            entries = entries.filter { $0.level == level }
        }

        if let source = source {
            entries = entries.filter {
                $0.source.localizedCaseInsensitiveContains(source)
            }
        }

        // Apply tail limit after filtering
        entries = Array(entries.suffix(tail))

        if entries.isEmpty {
            return .text("No log entries found matching the criteria. Total entries in buffer: \(buffer.totalCount)")
        }

        let formatted = entries.map { entry in
            let dateStr = timeFormatter.string(from: entry.timestamp)
            return "[\(dateStr)] [\(entry.level.uppercased())] [\(entry.source)] \(entry.message)"
        }.joined(separator: "\n")

        return .text("Log entries (\(entries.count) of \(buffer.totalCount) total):\n\n\(formatted)")
    }
}
