import XCTest
@testable import Apus

final class AppInfoInspectorTests: XCTestCase {

    var inspector: AppInfoInspector!

    override func setUp() {
        super.setUp()
        inspector = AppInfoInspector()
    }

    func testToolMetadata() {
        XCTAssertEqual(inspector.toolName, "get_app_info")
        XCTAssertFalse(inspector.toolDescription.isEmpty)
    }

    func testDefaultReturnsCompactSections() async throws {
        let result = try await inspector.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Default "all" = bundle + environment only
        XCTAssertTrue(text.contains("App Bundle:"), "Should include bundle section")
        XCTAssertTrue(text.contains("Environment:"), "Should include environment section")
        XCTAssertFalse(text.contains("Info.plist"), "Should NOT include plist section by default")
        XCTAssertFalse(text.contains("Loaded Frameworks"), "Should NOT include frameworks section by default")
    }

    func testFullSectionReturnsEverything() async throws {
        let result = try await inspector.execute(arguments: ["section": "full"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("App Bundle:"), "Should include bundle section")
        XCTAssertTrue(text.contains("Environment:"), "Should include environment section")
        XCTAssertTrue(text.contains("Info.plist"), "Should include plist section")
        XCTAssertTrue(text.contains("Loaded Frameworks"), "Should include frameworks section")
    }

    func testBundleSectionOnly() async throws {
        let result = try await inspector.execute(arguments: ["section": "bundle"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("App Bundle:"))
        XCTAssertTrue(text.contains("Bundle ID:"))
        XCTAssertFalse(text.contains("Environment:"))
    }

    func testEnvironmentSection() async throws {
        let result = try await inspector.execute(arguments: ["section": "environment"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Configuration:"))
        XCTAssertTrue(text.contains("DEBUG"))
        XCTAssertTrue(text.contains("OS Version:"))
        XCTAssertTrue(text.contains("Processor Count:"))
    }

    func testFrameworksSectionExplicitly() async throws {
        let result = try await inspector.execute(arguments: ["section": "frameworks"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Loaded Frameworks"))
    }

    func testPlistSectionExplicitly() async throws {
        let result = try await inspector.execute(arguments: ["section": "plist"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Info.plist"))
    }
}
