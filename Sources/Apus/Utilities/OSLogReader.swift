import Foundation
import OSLog

/// Reads system logs from the current process using OSLogStore.
/// Available on iOS 15+ / macOS 12+.
///
/// Filters out Apple system logs (`com.apple.*`) to only capture
/// app-level logs from the developer's code.
@available(iOS 15.0, macOS 12.0, *)
final class OSLogReader {

    private var lastReadDate: Date
    private let lock = NSLock()

    init() {
        self.lastReadDate = Date()
    }

    /// Fetch new log entries since the last read.
    /// Only captures app-level logs (filters out `com.apple.*` subsystems).
    func fetchNewEntries() -> [LogEntry] {
        lock.lock()
        let since = lastReadDate
        lock.unlock()

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "date > %@", since as NSDate)
            let entries = try store.getEntries(at: position, matching: predicate)

            var results: [LogEntry] = []
            var latestDate = since

            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }

                // Track the latest date regardless of filtering
                if logEntry.date > latestDate {
                    latestDate = logEntry.date
                }

                // Skip system subsystems — only capture app-level logs
                let subsystem = logEntry.subsystem
                if subsystem.hasPrefix("com.apple.") || subsystem.isEmpty {
                    continue
                }
                // Skip known system frameworks that don't use com.apple prefix
                if subsystem == "PrototypeTools" {
                    continue
                }

                let level = mapOSLogLevel(logEntry.level)
                let source: String
                if logEntry.category.isEmpty {
                    source = subsystem.isEmpty ? "os_log" : subsystem
                } else {
                    source = subsystem.isEmpty ? logEntry.category : "\(subsystem)/\(logEntry.category)"
                }

                results.append(LogEntry(
                    timestamp: logEntry.date,
                    level: level,
                    message: logEntry.composedMessage,
                    source: source
                ))
            }

            // Update last read date so we don't re-read
            lock.lock()
            if latestDate > self.lastReadDate {
                self.lastReadDate = latestDate
            }
            lock.unlock()

            return results
        } catch {
            return []
        }
    }

    /// Reset the read position to now (ignore older entries).
    func reset() {
        lock.lock()
        lastReadDate = Date()
        lock.unlock()
    }

    private func mapOSLogLevel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "info"
        case .error: return "error"
        case .fault: return "error"
        case .undefined: return "debug"
        @unknown default: return "debug"
        }
    }
}
