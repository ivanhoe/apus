import XCTest
@testable import Apus

// Test class for object inspection
private class TestViewModel {
    var name: String = "Test User"
    var count: Int = 42
    var isActive: Bool = true
    var items: [String] = ["alpha", "beta"]
}

private struct TestValueType {
    var label: String = "hello"
    var score: Double = 9.5
}

final class ObjectInspectorTests: XCTestCase {

    var inspector: ObjectInspector!

    override func setUp() {
        super.setUp()
        inspector = ObjectInspector()
    }

    override func tearDown() {
        inspector.unregister(id: "testObj")
        inspector.unregister(id: "testVal")
        inspector.unregister(id: "testProvider")
        super.tearDown()
    }

    func testToolMetadata() {
        XCTAssertEqual(inspector.toolName, "inspect_object")
        XCTAssertFalse(inspector.toolDescription.isEmpty)
    }

    func testListWhenEmpty() async throws {
        let result = try await inspector.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("No objects registered"))
    }

    func testRegisterAndInspectReferenceType() async throws {
        let vm = TestViewModel()
        inspector.register(vm, id: "testObj")

        let result = try await inspector.execute(arguments: ["id": "testObj"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("TestViewModel"))
        XCTAssertTrue(text.contains("name"))
        XCTAssertTrue(text.contains("Test User"))
    }

    func testRegisterAndInspectValueType() async throws {
        let val = TestValueType()
        inspector.register(val, id: "testVal")

        let result = try await inspector.execute(arguments: ["id": "testVal"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("TestValueType"))
        XCTAssertTrue(text.contains("hello"))
    }

    func testRegisterProviderClosure() async throws {
        var counter = 0
        inspector.register(id: "testProvider") {
            counter += 1
            return "call #\(counter)"
        }

        let result1 = try await inspector.execute(arguments: ["id": "testProvider"])
        guard case .text(let text1) = result1.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text1.contains("call #1"))

        let result2 = try await inspector.execute(arguments: ["id": "testProvider"])
        guard case .text(let text2) = result2.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text2.contains("call #2"))
    }

    func testInspectNonexistentObject() async throws {
        let result = try await inspector.execute(arguments: ["id": "doesNotExist"])
        XCTAssertTrue(result.isError)
    }

    func testListRegisteredObjects() async throws {
        let vm = TestViewModel()
        inspector.register(vm, id: "testObj")

        let result = try await inspector.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("testObj"))
        XCTAssertTrue(text.contains("TestViewModel"))
    }

    func testUnregister() async throws {
        let vm = TestViewModel()
        inspector.register(vm, id: "testObj")
        inspector.unregister(id: "testObj")

        let result = try await inspector.execute(arguments: ["id": "testObj"])
        XCTAssertTrue(result.isError)
    }

    func testWeakReferenceDeallocation() async throws {
        var vm: TestViewModel? = TestViewModel()
        inspector.register(vm!, id: "testObj")
        vm = nil // deallocate

        let result = try await inspector.execute(arguments: ["id": "testObj"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("deallocated"))
    }

    // MARK: - Schema validation

    func testSchemaHasIdParameter() {
        guard let properties = inspector.inputSchema["properties"] as? [String: Any],
              let idProp = properties["id"] as? [String: Any] else {
            XCTFail("Expected 'id' property in schema")
            return
        }
        XCTAssertEqual(idProp["type"] as? String, "string")
    }

    func testSchemaHasDepthParameter() {
        guard let properties = inspector.inputSchema["properties"] as? [String: Any],
              let depthProp = properties["depth"] as? [String: Any] else {
            XCTFail("Expected 'depth' property in schema")
            return
        }
        XCTAssertEqual(depthProp["type"] as? String, "integer")
    }

    func testSchemaType_isObject() {
        XCTAssertEqual(inspector.inputSchema["type"] as? String, "object")
    }

    // MARK: - Depth parameter

    func testInspectWithDepth1_producesNonErrorResult() async throws {
        let vm = TestViewModel()
        inspector.register(vm, id: "testObj")

        let result = try await inspector.execute(arguments: ["id": "testObj", "depth": 1])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("TestViewModel"))
    }

    func testInspectWithDepth0_stillShowsTypeName() async throws {
        let vm = TestViewModel()
        inspector.register(vm, id: "testObj")

        let result = try await inspector.execute(arguments: ["id": "testObj", "depth": 0])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("TestViewModel"))
    }

    // MARK: - Provider returning nil

    func testProviderReturningNil_returnsError() async throws {
        inspector.register(id: "nilProvider") { nil }
        defer { inspector.unregister(id: "nilProvider") }

        let result = try await inspector.execute(arguments: ["id": "nilProvider"])
        XCTAssertTrue(result.isError, "Provider returning nil should produce an error result")

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found") || text.contains("deallocated"),
                      "Error should describe why the object couldn't be inspected")
    }

    // MARK: - List output details

    func testListRegisteredObjects_includesCount() async throws {
        let vm1 = TestViewModel()
        let vm2 = TestViewModel()
        inspector.register(vm1, id: "testObj")
        inspector.register(vm2, id: "testObj2")
        defer { inspector.unregister(id: "testObj2") }

        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Registered objects (2):"),
                      "List should include exact registered object count header")
    }

    func testListRegisteredObjects_includesTypeNameForValueType() async throws {
        let val = TestValueType()
        inspector.register(val, id: "testVal")

        let result = try await inspector.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("TestValueType"),
                      "List should include the type name for each registered value-type object")
    }

    // MARK: - Concurrency / thread safety

    func testConcurrentRegistration_doesNotCrash() {
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                let vm = TestViewModel()
                let id = "concurrent_\(i)"
                self.inspector.register(vm, id: id)
                self.inspector.unregister(id: id)
                group.leave()
            }
        }
        // If we reach here without crashing, the NSLock is protecting state correctly
        XCTAssertEqual(group.wait(timeout: .now() + .seconds(5)), .success)
    }
}
