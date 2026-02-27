import XCTest
@testable import Apus

final class JSONHelperTests: XCTestCase {

    // MARK: - serialize(_:prettyPrinted:)

    func testSerialize_validDictionary_returnsData() {
        let dict: [String: Any] = ["key": "value", "number": 42]
        let data = JSONHelper.serialize(dict)
        XCTAssertNotNil(data, "Should return data for a valid dictionary")
    }

    func testSerialize_validArray_returnsData() {
        let array: [Any] = [1, "two", 3.0]
        let data = JSONHelper.serialize(array)
        XCTAssertNotNil(data, "Should return data for a valid array")
    }

    func testSerialize_scalarString_wrapsInValueKey() {
        let data = JSONHelper.serialize("hello")
        XCTAssertNotNil(data, "Should wrap scalar string and return data")

        guard let data = data, let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a dictionary with _value key")
            return
        }
        XCTAssertEqual(parsed["_value"] as? String, "hello")
    }

    func testSerialize_scalarInt_wrapsInValueKey() {
        let data = JSONHelper.serialize(99)
        XCTAssertNotNil(data)

        guard let data = data, let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected a dictionary with _value key")
            return
        }
        XCTAssertEqual(parsed["_value"] as? Int, 99)
    }

    func testSerialize_prettyPrinted_containsNewlines() {
        let dict: [String: Any] = ["a": 1, "b": 2]
        let data = JSONHelper.serialize(dict, prettyPrinted: true)
        XCTAssertNotNil(data)
        let string = String(data: data!, encoding: .utf8)!
        XCTAssertTrue(string.contains("\n"), "Pretty-printed JSON should contain newlines")
    }

    func testSerialize_notPrettyPrinted_isSingleLine() {
        let dict: [String: Any] = ["a": 1, "b": 2]
        let data = JSONHelper.serialize(dict, prettyPrinted: false)
        XCTAssertNotNil(data)
        let string = String(data: data!, encoding: .utf8)!
        XCTAssertFalse(string.contains("\n"), "Compact JSON should not contain newlines")
    }

    func testSerialize_sortedKeys_producesConsistentOutput() {
        let dict: [String: Any] = ["z": 1, "a": 2, "m": 3]
        let data1 = JSONHelper.serialize(dict)
        let data2 = JSONHelper.serialize(dict)
        XCTAssertNotNil(data1)
        XCTAssertNotNil(data2)
        // Sorted keys means same input always produces same bytes
        XCTAssertEqual(data1, data2, "Serialization should be deterministic with sortedKeys")
    }

    func testSerialize_nestedDictionary_preservesStructure() {
        let dict: [String: Any] = [
            "person": ["name": "Ivan", "age": 30] as [String: Any]
        ]
        let data = JSONHelper.serialize(dict)
        XCTAssertNotNil(data)

        guard let data = data,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let person = parsed["person"] as? [String: Any] else {
            XCTFail("Expected nested structure to be preserved")
            return
        }
        XCTAssertEqual(person["name"] as? String, "Ivan")
        XCTAssertEqual(person["age"] as? Int, 30)
    }

    func testSerialize_emptyDictionary_returnsEmptyObject() {
        let data = JSONHelper.serialize([String: Any]())
        XCTAssertNotNil(data)
        guard let data = data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected serialized JSON object")
            return
        }
        XCTAssertTrue(object.isEmpty, "Expected an empty JSON object")
    }

    func testSerialize_emptyArray_returnsEmptyArray() {
        let data = JSONHelper.serialize([Any]())
        XCTAssertNotNil(data)
        guard let data = data,
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            XCTFail("Expected serialized JSON array")
            return
        }
        XCTAssertTrue(array.isEmpty, "Expected an empty JSON array")
    }

    // MARK: - serializeToString(_:prettyPrinted:)

    func testSerializeToString_validDictionary_returnsJSONString() {
        let dict: [String: Any] = ["name": "Apus", "version": 1]
        let result = JSONHelper.serializeToString(dict)
        XCTAssertTrue(result.contains("Apus"), "Should contain the value")
        XCTAssertTrue(result.contains("name"), "Should contain the key")
    }

    func testSerializeToString_validArray_returnsJSONString() {
        let array: [Any] = ["a", "b", "c"]
        let result = JSONHelper.serializeToString(array)
        XCTAssertTrue(result.contains("\"a\""))
        XCTAssertTrue(result.contains("\"b\""))
    }

    func testSerializeToString_nonSerializableType_fallsBackToDescription() {
        // A raw URL is not JSON-serializable and can't be wrapped easily
        // We use a custom struct that JSONSerialization can't handle
        struct NonSerializable {}
        let value = NonSerializable()
        let result = JSONHelper.serializeToString(value)
        // Should fall back to String(describing:)
        XCTAssertFalse(result.isEmpty, "Should return a non-empty fallback string")
    }

    func testSerializeToString_emptyDictionary_returnsValidJSON() {
        let result = JSONHelper.serializeToString([String: Any]())
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("{"))
    }

    // MARK: - parse(_:)

    func testParse_validJSONObject_returnsDictionary() {
        let json = "{\"key\":\"value\",\"count\":5}"
        let data = json.data(using: .utf8)!
        let parsed = JSONHelper.parse(data)
        XCTAssertNotNil(parsed)
        if let dict = parsed as? [String: Any] {
            XCTAssertEqual(dict["key"] as? String, "value")
            XCTAssertEqual(dict["count"] as? Int, 5)
        } else {
            XCTFail("Expected dictionary")
        }
    }

    func testParse_validJSONArray_returnsArray() {
        let json = "[1,2,3]"
        let data = json.data(using: .utf8)!
        let parsed = JSONHelper.parse(data)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed is [Any])
    }

    func testParse_invalidJSON_returnsNil() {
        let invalid = "not json at all {{{".data(using: .utf8)!
        let parsed = JSONHelper.parse(invalid)
        XCTAssertNil(parsed, "Invalid JSON should return nil")
    }

    func testParse_emptyData_returnsNil() {
        let parsed = JSONHelper.parse(Data())
        XCTAssertNil(parsed, "Empty data should return nil")
    }

    func testParse_nestedJSON_preservesStructure() {
        let json = "{\"outer\":{\"inner\":\"deep\"}}"
        let data = json.data(using: .utf8)!
        let parsed = JSONHelper.parse(data) as? [String: Any]
        XCTAssertNotNil(parsed)
        let outer = parsed?["outer"] as? [String: Any]
        XCTAssertEqual(outer?["inner"] as? String, "deep")
    }

    // MARK: - parseAsDictionary(_:)

    func testParseAsDictionary_validJSONObject_returnsDictionary() {
        let json = "{\"toolName\":\"inspect_object\"}"
        let data = json.data(using: .utf8)!
        let result = JSONHelper.parseAsDictionary(data)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["toolName"] as? String, "inspect_object")
    }

    func testParseAsDictionary_jsonArray_returnsNil() {
        let json = "[1,2,3]"
        let data = json.data(using: .utf8)!
        let result = JSONHelper.parseAsDictionary(data)
        XCTAssertNil(result, "Array JSON should not parse as dictionary")
    }

    func testParseAsDictionary_invalidJSON_returnsNil() {
        let invalid = "bad data".data(using: .utf8)!
        let result = JSONHelper.parseAsDictionary(invalid)
        XCTAssertNil(result, "Invalid JSON should return nil")
    }

    func testParseAsDictionary_emptyObject_returnsEmptyDictionary() {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let result = JSONHelper.parseAsDictionary(data)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isEmpty)
    }

    // MARK: - Round-trip

    func testRoundTrip_dictionarySerializeAndParse_preservesValues() {
        let original: [String: Any] = ["name": "Apus", "port": 9847, "enabled": true]
        guard let data = JSONHelper.serialize(original) else {
            XCTFail("Serialization failed")
            return
        }
        guard let parsed = JSONHelper.parseAsDictionary(data) else {
            XCTFail("Parsing failed")
            return
        }
        XCTAssertEqual(parsed["name"] as? String, "Apus")
        XCTAssertEqual(parsed["port"] as? Int, 9847)
        XCTAssertEqual(parsed["enabled"] as? Bool, true)
    }
}
