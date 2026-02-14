import XCTest
@testable import Apus

final class LogCaptureTests: XCTestCase {

    var logCapture: LogCapture!

    override func setUp() {
        super.setUp()
        logCapture = LogCapture(bufferSize: 100)
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
}
