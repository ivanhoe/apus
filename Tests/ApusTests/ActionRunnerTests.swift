import XCTest
@testable import Apus

final class ActionRunnerTests: XCTestCase {

    var runner: ActionRunner!

    override func setUp() {
        super.setUp()
        runner = ActionRunner()
    }

    func testToolMetadata() {
        XCTAssertEqual(runner.toolName, "execute_action")
        XCTAssertFalse(runner.toolDescription.isEmpty)
        XCTAssertNotNil(runner.inputSchema["properties"])
    }

    // MARK: - List Actions

    func testListActionsWhenEmpty() async throws {
        let result = try await runner.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("No actions registered"))
    }

    func testListActionsShowsRegistered() async throws {
        runner.register(name: "clear_cache", description: "Clear all caches") { nil }
        runner.register(name: "reset_state", description: "Reset app state") { nil }

        let result = try await runner.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("clear_cache"))
        XCTAssertTrue(text.contains("Clear all caches"))
        XCTAssertTrue(text.contains("reset_state"))
        XCTAssertTrue(text.contains("2"))
    }

    // MARK: - Execute Actions

    func testExecuteActionSuccess() async throws {
        var executed = false
        runner.register(name: "do_thing", description: "Does a thing") {
            executed = true
            return "Thing was done!"
        }

        let result = try await runner.execute(arguments: ["name": "do_thing"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(executed)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertEqual(text, "Thing was done!")
    }

    func testExecuteActionWithNilReturn() async throws {
        runner.register(name: "silent", description: "Silent action") { nil }

        let result = try await runner.execute(arguments: ["name": "silent"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("executed successfully"))
    }

    func testExecuteActionNotFound() async throws {
        let result = try await runner.execute(arguments: ["name": "nonexistent"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"))
    }

    func testExecuteActionThatThrows() async throws {
        runner.register(name: "crashy", description: "This action throws") {
            throw NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        }

        let result = try await runner.execute(arguments: ["name": "crashy"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("failed"))
        XCTAssertTrue(text.contains("Something went wrong"))
    }

    // MARK: - Unregister

    func testUnregisterAction() async throws {
        runner.register(name: "temp", description: "Temporary") { nil }

        // Should exist
        let result1 = try await runner.execute(arguments: [:])
        guard case .text(let text1) = result1.content.first else {
            XCTFail("Expected text")
            return
        }
        XCTAssertTrue(text1.contains("temp"))

        // Unregister
        runner.unregister(name: "temp")

        // Should not exist
        let result2 = try await runner.execute(arguments: ["name": "temp"])
        XCTAssertTrue(result2.isError)
    }
}
