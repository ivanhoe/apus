import XCTest
@testable import Apus

final class MemoryInspectorTests: XCTestCase {

    var inspector: MemoryInspector!

    override func setUp() {
        super.setUp()
        inspector = MemoryInspector()
    }

    func testToolMetadata() {
        XCTAssertEqual(inspector.toolName, "get_memory_stats")
        XCTAssertFalse(inspector.toolDescription.isEmpty)
        XCTAssertNotNil(inspector.inputSchema["properties"])
    }

    func testReturnsMemoryStats() async throws {
        let result = try await inspector.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Should contain key memory sections
        XCTAssertTrue(text.contains("Physical footprint:"), "Should include physical footprint")
        XCTAssertTrue(text.contains("Resident size:"), "Should include resident size")
        XCTAssertTrue(text.contains("System Available Memory:"), "Should include available memory")
        XCTAssertTrue(text.contains("Heap"), "Should include heap stats")
        XCTAssertTrue(text.contains("In use:"), "Should include heap in-use")
    }

    func testIncludeZonesBreakdown() async throws {
        let result = try await inspector.execute(arguments: ["include_zones": true])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Heap zones:"), "Should include per-zone breakdown")
    }

    func testMemoryValuesAreReasonable() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Physical footprint should show MB (a running test process uses at least a few MB)
        XCTAssertTrue(text.contains("MB") || text.contains("GB"), "Memory values should be in MB or GB range")
    }

    // MARK: - Schema validation

    func testSchemaHasIncludeZonesProperty() {
        guard let properties = inspector.inputSchema["properties"] as? [String: Any],
              let includeZones = properties["include_zones"] as? [String: Any] else {
            XCTFail("Expected 'include_zones' property in schema")
            return
        }
        XCTAssertEqual(includeZones["type"] as? String, "boolean")
    }

    func testSchemaType_isObject() {
        XCTAssertEqual(inspector.inputSchema["type"] as? String, "object")
    }

    // MARK: - include_zones: false behaviour

    func testIncludeZonesFalse_excludesZonesBreakdown() async throws {
        let result = try await inspector.execute(arguments: ["include_zones": false])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertFalse(text.contains("Heap zones:"),
                       "include_zones: false should exclude the per-zone breakdown")
    }

    func testDefaultBehavior_doesNotIncludeZones() async throws {
        // No argument should behave the same as include_zones: false
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertFalse(text.contains("Heap zones:"),
                       "Default behaviour should not include per-zone breakdown")
    }

    // MARK: - Output section coverage

    func testOutput_containsVirtualSize() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Virtual size:"), "Output should include Virtual size field")
    }

    func testOutput_containsPeakResident() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Peak resident:"), "Output should include Peak resident field")
    }

    func testOutput_containsCompressedField() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Compressed:"), "Output should include Compressed memory field")
    }

    func testOutput_containsHeapBlockCount() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("blocks"), "Heap section should include block count")
    }

    func testOutput_containsInternalAndExternalFields() async throws {
        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Internal (app data):"), "Output should include Internal memory field")
        XCTAssertTrue(text.contains("External (shared):"), "Output should include External memory field")
    }
}
