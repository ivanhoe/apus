import Foundation

/// Helpers for JSON serialization using Foundation's JSONSerialization.
enum JSONHelper {

    /// Serialize a value to JSON Data. Returns nil if not serializable.
    static func serialize(_ value: Any, prettyPrinted: Bool = true) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else {
            // Try wrapping scalar values
            let wrapped = ["_value": value]
            guard JSONSerialization.isValidJSONObject(wrapped) else { return nil }
            var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
            if prettyPrinted { options.insert(.prettyPrinted) }
            return try? JSONSerialization.data(withJSONObject: wrapped, options: options)
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        if prettyPrinted { options.insert(.prettyPrinted) }
        return try? JSONSerialization.data(withJSONObject: value, options: options)
    }

    /// Serialize a value to a JSON String.
    static func serializeToString(_ value: Any, prettyPrinted: Bool = true) -> String {
        if let data = serialize(value, prettyPrinted: prettyPrinted),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    /// Parse JSON Data into a Foundation object.
    static func parse(_ data: Data) -> Any? {
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Parse JSON Data as a dictionary.
    static func parseAsDictionary(_ data: Data) -> [String: Any]? {
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
