import XCTest
@testable import Apus

private class SampleObject {
    var name: String = "Ivan"
    var age: Int = 30
    var scores: [Double] = [95.5, 87.3]
    var metadata: [String: String] = ["role": "admin"]
}

private class SelfReferencing {
    var name: String = "cycle"
    var myself: SelfReferencing?
}

private class NodeA {
    var label: String = "A"
    var partner: NodeB?
}

private class NodeB {
    var label: String = "B"
    var partner: NodeA?
}

private struct SampleStruct {
    var label: String = "test"
    var count: Int = 5
    var optional: String? = nil
    var optionalWithValue: String? = "present"
}

final class MirrorHelperTests: XCTestCase {

    func testInspectClassObject() {
        let obj = SampleObject()
        let result = MirrorHelper.inspect(obj, depth: 3)

        XCTAssertEqual(result["_type"] as? String, "SampleObject")
        XCTAssertNotNil(result["name"])
        XCTAssertNotNil(result["age"])
    }

    func testInspectStruct() {
        let val = SampleStruct()
        let result = MirrorHelper.inspect(val, depth: 3)

        XCTAssertEqual(result["_type"] as? String, "SampleStruct")
        XCTAssertEqual(result["label"] as? String, "test")
        XCTAssertEqual(result["count"] as? String, "5")
    }

    func testInspectOptionalNil() {
        let val = SampleStruct()
        let result = MirrorHelper.inspect(val, depth: 3)

        XCTAssertEqual(result["optional"] as? String, "nil")
    }

    func testInspectOptionalWithValue() {
        let val = SampleStruct()
        let result = MirrorHelper.inspect(val, depth: 3)

        // Optional("present") gets inspected as a nested dict at depth > 1
        if let nested = result["optionalWithValue"] as? [String: Any] {
            let desc = String(describing: nested)
            XCTAssertTrue(desc.contains("present"), "Expected 'present' in \(desc)")
        } else if let str = result["optionalWithValue"] as? String {
            XCTAssertTrue(str.contains("present"))
        } else {
            XCTFail("Expected optionalWithValue to be present in result")
        }
    }

    func testDepthLimit() {
        let obj = SampleObject()
        let shallow = MirrorHelper.inspect(obj, depth: 0)

        // At depth 0, should have _type and _value but not drill into properties
        XCTAssertNotNil(shallow["_type"])
        XCTAssertNotNil(shallow["_value"])
    }

    func testCircularReference_doesNotCrash() {
        let obj = SelfReferencing()
        obj.myself = obj

        // Should not crash or hang — cycle detection kicks in
        let result = MirrorHelper.inspect(obj, depth: 10)
        XCTAssertEqual(result["_type"] as? String, "SelfReferencing")
        XCTAssertEqual(result["name"] as? String, "cycle")

        // The circular ref should be detected
        if let myselfDict = result["myself"] as? [String: Any] {
            let desc = String(describing: myselfDict)
            XCTAssertTrue(desc.contains("circular reference"), "Expected circular reference marker in \(desc)")
        }
    }

    func testMutualCircularReference_doesNotCrash() {
        let a = NodeA()
        let b = NodeB()
        a.partner = b
        b.partner = a

        // Should not crash or hang — cycle detection kicks in
        let result = MirrorHelper.inspect(a, depth: 10)
        XCTAssertEqual(result["_type"] as? String, "NodeA")
    }

    func testInspectPrimitiveTypes() {
        let intResult = MirrorHelper.inspect(42, depth: 1)
        XCTAssertEqual(intResult["_type"] as? String, "Int")
        XCTAssertEqual(intResult["_value"] as? String, "42")

        let stringResult = MirrorHelper.inspect("hello", depth: 1)
        XCTAssertEqual(stringResult["_type"] as? String, "String")
        XCTAssertEqual(stringResult["_value"] as? String, "hello")

        let boolResult = MirrorHelper.inspect(true, depth: 1)
        XCTAssertEqual(boolResult["_type"] as? String, "Bool")
        XCTAssertEqual(boolResult["_value"] as? String, "true")
    }
}
