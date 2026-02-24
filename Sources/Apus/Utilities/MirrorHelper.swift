import Foundation

/// Utilities for inspecting objects using Swift's Mirror reflection.
enum MirrorHelper {

    /// Inspect an object and return a dictionary representation of its properties.
    static func inspect(_ object: Any, depth: Int = 3) -> [String: Any] {
        return inspectValue(object, currentDepth: 0, maxDepth: depth, visited: Set())
    }

    private static func inspectValue(_ value: Any, currentDepth: Int, maxDepth: Int, visited: Set<ObjectIdentifier>) -> [String: Any] {
        var visited = visited

        // Cycle detection for reference types
        if type(of: value) is AnyClass {
            let id = ObjectIdentifier(value as AnyObject)
            if visited.contains(id) {
                return [
                    "_type": String(describing: type(of: value)),
                    "_value": "<circular reference>"
                ]
            }
            visited.insert(id)
        }

        let mirror = Mirror(reflecting: value)
        var result: [String: Any] = [
            "_type": String(describing: type(of: value))
        ]

        if currentDepth >= maxDepth {
            result["_value"] = truncate(String(describing: value))
            return result
        }

        if mirror.children.isEmpty {
            result["_value"] = truncate(String(describing: value))
        } else {
            for child in mirror.children {
                let key = child.label ?? "_\(result.count)"
                let childMirror = Mirror(reflecting: child.value)
                if childMirror.children.isEmpty || currentDepth + 1 >= maxDepth {
                    result[key] = stringRepresentation(child.value)
                } else {
                    result[key] = inspectValue(child.value, currentDepth: currentDepth + 1, maxDepth: maxDepth, visited: visited)
                }
            }
        }

        return result
    }

    private static func stringRepresentation(_ value: Any) -> String {
        if let optional = value as? OptionalProtocol {
            if optional.isNil {
                return "nil"
            }
            return truncate(String(describing: optional.wrappedValue))
        }
        return truncate(String(describing: value))
    }

    private static func truncate(_ str: String, maxLength: Int = 200) -> String {
        if str.count > maxLength {
            return String(str.prefix(maxLength)) + "... (\(str.count) chars)"
        }
        return str
    }
}

// Helper to detect Optional values via protocol conformance
private protocol OptionalProtocol {
    var isNil: Bool { get }
    var wrappedValue: Any { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
    var wrappedValue: Any { self as Any }
}
