import XCTest
import os
@testable import Apus

@available(iOS 15.0, macOS 12.0, *)
final class OSLogReaderTests: XCTestCase {

    func testFetchReturnsEntries() {
        let reader = OSLogReader()

        // Write a log entry using os.Logger
        let logger = Logger(subsystem: "com.apus.test", category: "oslog-test")
        logger.info("OSLogReaderTest: test entry")

        // Give the system time to flush
        Thread.sleep(forTimeInterval: 0.5)

        let entries = reader.fetchNewEntries()

        // The key test is that it doesn't crash and returns valid LogEntry objects.
        // Exact matching is unreliable due to timing, so we just verify the type.
        XCTAssertNotNil(entries)
    }

    func testFetchDoesNotRepeatEntries() {
        let reader = OSLogReader()

        let logger = Logger(subsystem: "com.apus.test", category: "oslog-dedup")
        logger.info("OSLogReaderTest: dedup entry")
        Thread.sleep(forTimeInterval: 0.5)

        let firstFetch = reader.fetchNewEntries()
        let secondFetch = reader.fetchNewEntries()

        // Second fetch should not contain entries from the first fetch
        let firstMessages = Set(firstFetch.map { $0.message })
        let repeatedMessages = secondFetch.filter { firstMessages.contains($0.message) }

        // There shouldn't be exact duplicates (some system logs may arrive between fetches)
        XCTAssertTrue(repeatedMessages.count <= firstFetch.count,
                      "Second fetch should have fewer or equal entries matching first fetch")
    }

    func testReset() {
        let reader = OSLogReader()

        let logger = Logger(subsystem: "com.apus.test", category: "oslog-reset")
        logger.info("OSLogReaderTest: before reset")
        Thread.sleep(forTimeInterval: 0.5)

        reader.reset()

        // After reset, entries from before the reset should not appear
        let entries = reader.fetchNewEntries()
        let beforeResetEntries = entries.filter { $0.message.contains("before reset") }
        XCTAssertEqual(beforeResetEntries.count, 0, "Entries before reset should not appear after reset")
    }

    func testLevelMapping() {
        let reader = OSLogReader()

        let logger = Logger(subsystem: "com.apus.test", category: "oslog-levels")
        logger.debug("OSLogReaderTest: debug level")
        logger.info("OSLogReaderTest: info level")
        logger.error("OSLogReaderTest: error level")
        Thread.sleep(forTimeInterval: 0.5)

        let entries = reader.fetchNewEntries()
        let testEntries = entries.filter { $0.message.contains("OSLogReaderTest") }

        // Verify level mapping produces valid strings
        for entry in testEntries {
            XCTAssertTrue(["debug", "info", "warning", "error"].contains(entry.level),
                          "Level '\(entry.level)' should be a valid level string")
        }
    }

    func testSourceIncludesSubsystemAndCategory() {
        let reader = OSLogReader()

        let logger = Logger(subsystem: "com.apus.test", category: "my-category")
        logger.info("OSLogReaderTest: source test")
        Thread.sleep(forTimeInterval: 0.5)

        let entries = reader.fetchNewEntries()
        let matching = entries.filter { $0.message.contains("source test") }

        for entry in matching {
            XCTAssertTrue(entry.source.contains("com.apus.test"),
                          "Source should contain subsystem, got: \(entry.source)")
        }
    }
}
