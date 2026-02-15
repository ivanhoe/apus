import XCTest
@testable import Apus

final class DiagnosticsToolTests: XCTestCase {

    func testToolMetadata() {
        let tool = makeTool()
        XCTAssertEqual(tool.toolName, "get_diagnostics")
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testReturnsAllSections() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Should contain all major sections
        XCTAssertTrue(text.contains("App:"), "Should contain app info section")
        XCTAssertTrue(text.contains("Memory:"), "Should contain memory section")
        XCTAssertTrue(text.contains("Recent Errors:"), "Should contain errors section")
        XCTAssertTrue(text.contains("Network:"), "Should contain network section")
        XCTAssertTrue(text.contains("UserDefaults:"), "Should contain defaults section")
        XCTAssertTrue(text.contains("Status:"), "Should contain status section")
    }

    func testShowsAppInfo() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // App section is now a compact one-liner
        XCTAssertTrue(text.contains("App:"), "Should show app info")
        XCTAssertTrue(text.contains("PID"), "Should show process ID")
    }

    func testShowsMemoryStats() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("peak:"), "Should show peak memory")
        XCTAssertTrue(text.contains("Heap:"), "Should show heap stats")
        XCTAssertTrue(text.contains("blocks"), "Should show block count")
    }

    func testShowsRecentErrors() async throws {
        let logCapture = LogCapture(bufferSize: 100)
        logCapture.log("Token expired", level: "error", source: "Auth")
        logCapture.log("Connection timeout", level: "error", source: "DB")
        logCapture.log("This is info", level: "info", source: "App")

        let tool = makeTool(logCapture: logCapture)
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Recent Errors (2 total"), "Should show 2 errors")
        XCTAssertTrue(text.contains("Token expired"), "Should include error message")
        XCTAssertTrue(text.contains("Connection timeout"), "Should include error message")
        XCTAssertFalse(text.contains("This is info"), "Should NOT include info logs")
    }

    func testShowsNoErrorsWhenClean() async throws {
        let logCapture = LogCapture(bufferSize: 100)
        logCapture.log("All good", level: "info", source: "App")

        let tool = makeTool(logCapture: logCapture)
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Recent Errors: none"), "Should say no errors")
    }

    func testNetworkNotEnabled() async throws {
        let tool = makeTool(networkInterceptor: nil)
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("interception not enabled"), "Should note network not enabled")
    }

    func testShowsToolAndActionCounts() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("tools active"), "Should show tool count")
        XCTAssertTrue(text.contains("actions registered"), "Should show action count")
    }

    func testIsNotError() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])
        XCTAssertFalse(result.isError)
    }

    func testNoDividerLines() async throws {
        let tool = makeTool()
        let result = try await tool.execute(arguments: [:])

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertFalse(text.contains("─"), "Should not contain long divider lines")
    }

    // MARK: - Helpers

    private func makeTool(
        logCapture: LogCapture? = nil,
        networkInterceptor: NetworkInterceptor? = NetworkInterceptor()
    ) -> DiagnosticsTool {
        let log = logCapture ?? LogCapture(bufferSize: 100)
        let runner = ActionRunner()
        let registry = ToolRegistry()
        registry.register(log)
        registry.register(runner)

        return DiagnosticsTool(
            logCapture: log,
            networkInterceptor: networkInterceptor,
            actionRunner: runner,
            toolRegistry: registry
        )
    }
}
