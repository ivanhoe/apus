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
}
