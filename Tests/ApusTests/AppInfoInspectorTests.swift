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

    // MARK: - Schema validation

    func testSchemaHasSectionParameter() {
        guard let properties = inspector.inputSchema["properties"] as? [String: Any],
              let section = properties["section"] as? [String: Any] else {
            XCTFail("Expected 'section' property in schema")
            return
        }
        XCTAssertEqual(section["type"] as? String, "string")
        guard let enumValues = section["enum"] as? [String] else {
            XCTFail("Expected 'enum' array in section schema")
            return
        }
        XCTAssertTrue(enumValues.contains("all"))
        XCTAssertTrue(enumValues.contains("full"))
        XCTAssertTrue(enumValues.contains("bundle"))
        XCTAssertTrue(enumValues.contains("plist"))
        XCTAssertTrue(enumValues.contains("frameworks"))
        XCTAssertTrue(enumValues.contains("environment"))
    }

    func testSchemaType_isObject() {
        XCTAssertEqual(inspector.inputSchema["type"] as? String, "object")
    }

    // MARK: - Section content detail

    func testBundleSection_hasBundlePath() async throws {
        let result = try await inspector.execute(arguments: ["section": "bundle"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Bundle Path:"), "Bundle section should include Bundle Path field")
    }

    func testBundleSection_hasMinOSField() async throws {
        let result = try await inspector.execute(arguments: ["section": "bundle"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Min OS:"), "Bundle section should include Min OS field")
    }

    func testEnvironmentSection_hasArchitectureField() async throws {
        let result = try await inspector.execute(arguments: ["section": "environment"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Architecture:"), "Environment should include Architecture field")
    }

    func testEnvironmentSection_hasThermalState() async throws {
        let result = try await inspector.execute(arguments: ["section": "environment"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Thermal State:"), "Environment should include Thermal State field")
    }

    func testEnvironmentSection_hasLowPowerMode() async throws {
        let result = try await inspector.execute(arguments: ["section": "environment"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Low Power Mode:"), "Environment should include Low Power Mode field")
    }

    func testPlistSection_showsEntryCount() async throws {
        let result = try await inspector.execute(arguments: ["section": "plist"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Format is "Info.plist (N entries):" or "Info.plist: unavailable"
        XCTAssertTrue(text.contains("entries") || text.contains("unavailable"),
                      "Plist section should show entry count or unavailability notice")
    }

    func testFrameworksSection_showsTotalCount() async throws {
        let result = try await inspector.execute(arguments: ["section": "frameworks"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Format: "Loaded Frameworks (N app/third-party, M total):"
        XCTAssertTrue(text.contains("total"), "Frameworks section should include total count")
    }

    // MARK: - No errors for any section

    func testAllSections_noneReturnErrors() async throws {
        let sections = ["all", "full", "bundle", "environment", "plist", "frameworks"]
        for section in sections {
            let result = try await inspector.execute(arguments: ["section": section])
            XCTAssertFalse(result.isError, "Section '\(section)' should not return an error result")
        }
    }

    func testAllSections_haveNonEmptyTextContent() async throws {
        let sections = ["all", "full", "bundle", "environment", "plist", "frameworks"]
        for section in sections {
            let result = try await inspector.execute(arguments: ["section": section])
            guard case .text(let text) = result.content.first else {
                XCTFail("Section '\(section)': expected text content")
                continue
            }
            XCTAssertFalse(text.isEmpty, "Section '\(section)' should return non-empty text")
        }
    }
}
