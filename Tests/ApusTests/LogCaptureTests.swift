import XCTest
@testable import Apus

final class LogCaptureTests: XCTestCase {

    var logCapture: LogCapture!

    override func setUp() {
        super.setUp()
        logCapture = LogCapture(bufferSize: 100)
    }

    override func tearDown() {
        logCapture.stopSystemCapture()
        super.tearDown()
    }

    func testLogAndRetrieve() async throws {
        logCapture.log("Test message", level: "info", source: "test")

        let result = try await logCapture.execute(arguments: [:])
        XCTAssertFalse(result.isError)
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Test message"))
            XCTAssertTrue(text.contains("[INFO]"))
            XCTAssertTrue(text.contains("[test]"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testTailParameter() async throws {
        for i in 1...20 {
            logCapture.log("Message \(i)")
        }

        let result = try await logCapture.execute(arguments: ["tail": 5])
        if case .text(let text) = result.content.first {
            // Should only show last 5
            XCTAssertTrue(text.contains("Message 20"))
            XCTAssertTrue(text.contains("Message 16"))
            XCTAssertFalse(text.contains("Message 15"))
        }
    }

    func testGrepFilter() async throws {
        logCapture.log("Login successful")
        logCapture.log("Error: connection failed")
        logCapture.log("Error: timeout")
        logCapture.log("Login attempt")

        let result = try await logCapture.execute(arguments: ["grep": "Error"])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("connection failed"))
            XCTAssertTrue(text.contains("timeout"))
            XCTAssertFalse(text.contains("Login"))
        }
    }

    func testLevelFilter() async throws {
        logCapture.log("Debug info", level: "debug")
        logCapture.log("Normal info", level: "info")
        logCapture.log("Warning!", level: "warning")
        logCapture.log("Critical error", level: "error")

        let result = try await logCapture.execute(arguments: ["level": "error"])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Critical error"))
            XCTAssertFalse(text.contains("Debug info"))
            XCTAssertFalse(text.contains("Normal info"))
            XCTAssertFalse(text.contains("Warning!"))
        }
    }

    func testEmptyResults() async throws {
        let result = try await logCapture.execute(arguments: [:])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("No log entries found"))
        }
    }

    func testCombinedFilters() async throws {
        logCapture.log("Error in login", level: "error")
        logCapture.log("Error in payment", level: "error")
        logCapture.log("Info about login", level: "info")

        let result = try await logCapture.execute(arguments: [
            "level": "error",
            "grep": "login"
        ])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Error in login"))
            XCTAssertFalse(text.contains("Error in payment"))
            XCTAssertFalse(text.contains("Info about login"))
        }
    }

    func testToolMetadata() {
        XCTAssertEqual(logCapture.toolName, "get_logs")
        XCTAssertFalse(logCapture.toolDescription.isEmpty)
        XCTAssertEqual(logCapture.inputSchema["type"] as? String, "object")
    }

    // MARK: - Source filter tests

    func testSourceFilter() async throws {
        logCapture.log("Auth log", level: "info", source: "AuthService")
        logCapture.log("Network log", level: "info", source: "NetworkManager")
        logCapture.log("Auth error", level: "error", source: "AuthService")

        let result = try await logCapture.execute(arguments: ["source": "auth"])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Auth log"))
            XCTAssertTrue(text.contains("Auth error"))
            XCTAssertFalse(text.contains("Network log"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testSourceFilterCombinedWithLevel() async throws {
        logCapture.log("Auth info", level: "info", source: "AuthService")
        logCapture.log("Auth error", level: "error", source: "AuthService")
        logCapture.log("Net error", level: "error", source: "NetworkManager")

        let result = try await logCapture.execute(arguments: [
            "source": "auth",
            "level": "error"
        ])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Auth error"))
            XCTAssertFalse(text.contains("Auth info"))
            XCTAssertFalse(text.contains("Net error"))
        } else {
            XCTFail("Expected text content")
        }
    }

    func testSourceFilterStderr() async throws {
        logCapture.log("Manual log", level: "info", source: "app")
        logCapture.log("Print output", level: "info", source: "stderr")
        logCapture.log("Another print", level: "info", source: "stderr")

        let result = try await logCapture.execute(arguments: ["source": "stderr"])
        if case .text(let text) = result.content.first {
            XCTAssertTrue(text.contains("Print output"))
            XCTAssertTrue(text.contains("Another print"))
            XCTAssertFalse(text.contains("Manual log"))
        } else {
            XCTFail("Expected text content")
        }
    }

    // MARK: - Watermark (since) tests

    func testSinceReturnsOnlyNewEntries() async throws {
        logCapture.log("Old message 1")
        logCapture.log("Old message 2")

        // Get watermark from first call
        let result1 = try await logCapture.execute(arguments: [:])
        guard case .text(let text1) = result1.content.first else {
            XCTFail("Expected text content"); return
        }
        // Extract watermark from "watermark: N"
        let watermark = extractWatermark(from: text1)
        XCTAssertNotNil(watermark)

        // Add new entries
        logCapture.log("New message 1")
        logCapture.log("New message 2")

        let result2 = try await logCapture.execute(arguments: ["since": watermark!])
        guard case .text(let text2) = result2.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text2.contains("New message 1"))
        XCTAssertTrue(text2.contains("New message 2"))
        XCTAssertFalse(text2.contains("Old message"))
        XCTAssertTrue(text2.contains("watermark:"))
    }

    func testSinceNoNewEntries() async throws {
        logCapture.log("Message 1")

        let result1 = try await logCapture.execute(arguments: [:])
        let watermark = extractWatermark(from: textContent(result1))

        // No new entries added
        let result2 = try await logCapture.execute(arguments: ["since": watermark!])
        guard case .text(let text) = result2.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("No new log entries"))
        XCTAssertTrue(text.contains("watermark:"))
    }

    func testSinceWithFilters() async throws {
        logCapture.log("Error A", level: "error")
        let result1 = try await logCapture.execute(arguments: [:])
        let watermark = extractWatermark(from: textContent(result1))

        logCapture.log("Info B", level: "info")
        logCapture.log("Error C", level: "error")

        let result2 = try await logCapture.execute(arguments: ["since": watermark!, "level": "error"])
        let text = textContent(result2)
        XCTAssertTrue(text.contains("Error C"))
        XCTAssertFalse(text.contains("Info B"))
        XCTAssertFalse(text.contains("Error A"))
    }

    func testWithoutSinceStillWorks() async throws {
        logCapture.log("Message 1")
        logCapture.log("Message 2")

        let result = try await logCapture.execute(arguments: ["tail": 10])
        let text = textContent(result)
        XCTAssertTrue(text.contains("Message 1"))
        XCTAssertTrue(text.contains("Message 2"))
        XCTAssertTrue(text.contains("watermark:"))
    }

    // MARK: - Schema tests

    func testSchemaIncludesSourceParameter() {
        let properties = logCapture.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["source"], "Schema should include 'source' parameter")

        let sourceSchema = properties?["source"] as? [String: Any]
        XCTAssertEqual(sourceSchema?["type"] as? String, "string")
    }

    func testSchemaIncludesSinceParameter() {
        let properties = logCapture.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["since"], "Schema should include 'since' parameter")

        let sinceSchema = properties?["since"] as? [String: Any]
        XCTAssertEqual(sinceSchema?["type"] as? String, "integer")
    }

    func testToolDescriptionMentionsAllSources() {
        XCTAssertTrue(logCapture.toolDescription.contains("os_log"))
        XCTAssertTrue(logCapture.toolDescription.contains("print"))
        XCTAssertTrue(logCapture.toolDescription.contains("Apus.log"))
    }

    // MARK: - System capture lifecycle

    func testStartAndStopSystemCapture() {
        // Should not crash
        logCapture.startSystemCapture()
        logCapture.stopSystemCapture()

        // Double stop should be safe
        logCapture.stopSystemCapture()
    }

    // MARK: - Helpers

    private func textContent(_ result: MCPToolResult) -> String {
        if case .text(let text) = result.content.first { return text }
        return ""
    }

    private func extractWatermark(from text: String) -> Int? {
        // Match "watermark: 123" pattern
        guard let range = text.range(of: "watermark: \\d+", options: .regularExpression) else { return nil }
        let match = String(text[range])
        return Int(match.replacingOccurrences(of: "watermark: ", with: ""))
    }
}
