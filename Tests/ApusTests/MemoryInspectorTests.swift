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
}
