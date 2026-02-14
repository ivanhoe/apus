import XCTest
@testable import Apus

// Test class for runtime inspection
class SampleInspectableClass: NSObject {
    @objc var name: String = "test"
    @objc var count: Int = 42
    @objc var isActive: Bool = true

    @objc func doSomething() {}
    @objc func processItem(_ item: String) -> String { return item }
}

final class ClassInspectorTests: XCTestCase {

    var inspector: ClassInspector!

    override func setUp() {
        super.setUp()
        inspector = ClassInspector()
    }

    func testToolMetadata() {
        XCTAssertEqual(inspector.toolName, "list_classes")
        XCTAssertFalse(inspector.toolDescription.isEmpty)
    }

    func testListClassesWithSystemIncluded() async throws {
        let result = try await inspector.execute(arguments: ["include_system": true, "filter": "NSBundle", "limit": 5])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("NSBundle"))
    }

    func testInspectSpecificClass() async throws {
        // Ensure our test class is registered in the runtime
        _ = SampleInspectableClass()

        let result = try await inspector.execute(arguments: ["name": "SampleInspectableClass"])

        // The class might have a module prefix in the runtime
        if result.isError {
            // Try with module prefix
            let result2 = try await inspector.execute(arguments: ["name": "ApusTests.SampleInspectableClass"])
            guard case .text(let text) = result2.content.first else {
                XCTFail("Expected text content")
                return
            }
            XCTAssertTrue(text.contains("Properties") || text.contains("Methods"))
            return
        }

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("Inherits:"))
    }

    func testInspectNonexistentClass() async throws {
        let result = try await inspector.execute(arguments: ["name": "NonExistentClass12345"])
        XCTAssertTrue(result.isError)
    }

    func testFilterClasses() async throws {
        // Filter system framework classes with a known class name
        let result = try await inspector.execute(arguments: ["include_system": true, "filter": "NSString", "limit": 10])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("NSString"))
    }

    func testLimitWorks() async throws {
        let result = try await inspector.execute(arguments: ["include_system": true, "filter": "NSDate", "limit": 3])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        // Count indented lines (class entries)
        let classLines = text.split(separator: "\n").filter { $0.hasPrefix("  ") }
        XCTAssertLessThanOrEqual(classLines.count, 3)
    }
}
