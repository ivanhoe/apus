import Foundation
import ObjectiveC
import MachO

/// MCP tool that enumerates classes from the Objective-C runtime.
/// Lists app-specific classes with their properties, methods, and inheritance.
final class ClassInspector: MCPTool {
    var toolName: String { "list_classes" }
    var toolDescription: String {
        "List classes registered in the Objective-C runtime. By default shows only app-specific classes (not system frameworks). Use 'name' to inspect a specific class and see its properties, methods, and superclass chain."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Inspect a specific class by name. Shows properties, methods, protocols, and superclass chain."
                ] as [String: Any],
                "filter": [
                    "type": "string",
                    "description": "Filter class names containing this string (case-insensitive)"
                ] as [String: Any],
                "include_system": [
                    "type": "boolean",
                    "description": "Include system/framework classes (default: false, shows only app classes)"
                ] as [String: Any],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of classes to list (default: 100)"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        // Inspect a specific class
        if let name = arguments["name"] as? String {
            return inspectClass(name: name)
        }

        // List classes
        let filter = arguments["filter"] as? String
        let includeSystem = arguments["include_system"] as? Bool ?? false
        let limit = arguments["limit"] as? Int ?? 100

        return listClasses(filter: filter, includeSystem: includeSystem, limit: limit)
    }

    // MARK: - List Classes

    private func listClasses(filter: String?, includeSystem: Bool, limit: Int) -> MCPToolResult {
        var classes: [String] = []

        if includeSystem {
            if filter == nil {
                return .text("When using include_system: true, please provide a 'filter' to narrow results (e.g. filter: \"UIView\"). There are tens of thousands of system classes.")
            }
            // Use image-based enumeration scanning only .framework images
            let allNames = getFrameworkClassNames(filter: filter)
            for name in allNames {
                if name.hasPrefix("_") || name.hasPrefix("OS_") { continue }
                classes.append(name)
            }
        } else {
            // Use objc_copyClassNamesForImage for safe, fast enumeration of app classes only
            let appClasses = getAppClasses()
            for name in appClasses {
                if name.hasPrefix("_") || name.hasPrefix("__") { continue }
                if let filter = filter {
                    guard name.localizedCaseInsensitiveContains(filter) else { continue }
                }
                classes.append(name)
            }
        }

        classes.sort()

        let total = classes.count
        let displayed = Array(classes.prefix(limit))

        if displayed.isEmpty {
            if !includeSystem {
                return .text("No ObjC classes found in the app executable. Pure Swift/SwiftUI apps may not register ObjC classes. Try:\n  - include_system: true with a filter (e.g. filter: \"UIView\")\n  - name: \"ClassName\" to inspect a specific known class\n  - Use inspect_object for registered Swift objects")
            }
            return .text("No classes found matching the criteria.")
        }

        var lines: [String] = ["Classes (\(total) found\(total > limit ? ", showing first \(limit)" : "")):"]

        for name in displayed {
            lines.append("  \(name)")
        }

        return .text(lines.joined(separator: "\n"))
    }

    /// Get class names from the main executable image only (safe, no Bundle(for:) calls).
    private func getAppClasses() -> [String] {
        // Try multiple strategies to find the app's executable image
        let candidatePaths: [String] = {
            var paths: [String] = []

            // Strategy 1: Bundle.main.executablePath
            if let execPath = Bundle.main.executablePath {
                paths.append(execPath)
            }

            // Strategy 2: First dyld image (usually the main executable)
            if _dyld_image_count() > 0, let firstImage = _dyld_get_image_name(0) {
                paths.append(String(cString: firstImage))
            }

            return paths
        }()

        for path in candidatePaths {
            var count: UInt32 = 0
            guard let classNames = objc_copyClassNamesForImage(path, &count), count > 0 else {
                continue
            }
            defer { free(UnsafeMutableRawPointer(mutating: classNames)) }

            var names: [String] = []
            for i in 0..<Int(count) {
                names.append(String(cString: classNames[i]))
            }
            return names
        }

        return []
    }

    /// Get class names from framework images only (safe — uses objc_copyClassNamesForImage).
    /// Skips non-framework paths to keep enumeration fast.
    private func getFrameworkClassNames(filter: String?) -> [String] {
        var allNames: [String] = []

        let dyldCount = _dyld_image_count()
        for i in 0..<dyldCount {
            guard let imageName = _dyld_get_image_name(i) else { continue }
            let path = String(cString: imageName)

            // Only scan .framework images (skip dylibs, plugins, etc.)
            guard path.contains(".framework/") else { continue }

            var count: UInt32 = 0
            guard let names = objc_copyClassNamesForImage(path, &count) else { continue }
            defer { free(UnsafeMutableRawPointer(mutating: names)) }
            for j in 0..<Int(count) {
                let name = String(cString: names[j])
                if let filter = filter {
                    guard name.range(of: filter, options: .caseInsensitive) != nil else { continue }
                }
                allNames.append(name)
            }
        }
        return allNames
    }

    // MARK: - Inspect Specific Class

    private func inspectClass(name: String) -> MCPToolResult {
        guard let cls = NSClassFromString(name) else {
            return .error("Class '\(name)' not found in the runtime.")
        }

        var sections: [String] = []

        // Header
        sections.append("Class: \(name)")

        // Superclass chain
        let chain = superclassChain(for: cls)
        sections.append("Inherits: \(chain.joined(separator: " → "))")

        // Protocols
        let protocols = adoptedProtocols(for: cls)
        if !protocols.isEmpty {
            sections.append("Protocols: \(protocols.joined(separator: ", "))")
        }

        // Properties
        let props = classProperties(for: cls)
        if !props.isEmpty {
            sections.append("\nProperties (\(props.count)):")
            for prop in props {
                sections.append("  \(prop)")
            }
        }

        // Instance methods
        let methods = classMethods(for: cls, isClass: false)
        if !methods.isEmpty {
            sections.append("\nInstance Methods (\(methods.count)):")
            for method in methods.prefix(50) {
                sections.append("  \(method)")
            }
            if methods.count > 50 {
                sections.append("  ... and \(methods.count - 50) more")
            }
        }

        // Class methods
        let clsMethods = classMethods(for: cls, isClass: true)
        if !clsMethods.isEmpty {
            sections.append("\nClass Methods (\(clsMethods.count)):")
            for method in clsMethods.prefix(20) {
                sections.append("  \(method)")
            }
            if clsMethods.count > 20 {
                sections.append("  ... and \(clsMethods.count - 20) more")
            }
        }

        return .text(sections.joined(separator: "\n"))
    }

    // MARK: - Runtime Helpers

    private func getAllClasses() -> [AnyClass] {
        var count: UInt32 = 0
        guard let classList = objc_copyClassList(&count) else { return [] }
        defer { free(UnsafeMutableRawPointer(classList)) }

        var classes: [AnyClass] = []
        for i in 0..<Int(count) {
            classes.append(classList[i])
        }
        return classes
    }

    private func superclassChain(for cls: AnyClass) -> [String] {
        var chain: [String] = [NSStringFromClass(cls)]
        var current: AnyClass? = class_getSuperclass(cls)
        while let superclass = current {
            chain.append(NSStringFromClass(superclass))
            current = class_getSuperclass(superclass)
        }
        return chain
    }

    private func adoptedProtocols(for cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let protocols = class_copyProtocolList(cls, &count) else { return [] }
        defer { free(UnsafeMutableRawPointer(mutating: protocols)) }

        var names: [String] = []
        for i in 0..<Int(count) {
            names.append(String(cString: protocol_getName(protocols[i])))
        }
        return names.sorted()
    }

    private func classProperties(for cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(properties) }

        var props: [String] = []
        for i in 0..<Int(count) {
            let name = String(cString: property_getName(properties[i]))
            let attrs = property_getAttributes(properties[i]).map { String(cString: $0) } ?? ""
            let type = parsePropertyType(attrs)
            props.append("\(name): \(type)")
        }
        return props.sorted()
    }

    private func classMethods(for cls: AnyClass, isClass: Bool) -> [String] {
        let target: AnyClass? = isClass ? object_getClass(cls) : cls
        guard let target = target else { return [] }

        var count: UInt32 = 0
        guard let methods = class_copyMethodList(target, &count) else { return [] }
        defer { free(methods) }

        var names: [String] = []
        for i in 0..<Int(count) {
            let selector = method_getName(methods[i])
            let name = NSStringFromSelector(selector)
            // Skip internal/private methods
            if name.hasPrefix(".") || name.hasPrefix("_") { continue }
            names.append(name)
        }
        return names.sorted()
    }

    private func parsePropertyType(_ attributes: String) -> String {
        // ObjC property attributes format: T@"NSString",N,R,V_name
        let components = attributes.split(separator: ",")
        guard let typeAttr = components.first, typeAttr.hasPrefix("T") else {
            return "unknown"
        }

        let typeStr = String(typeAttr.dropFirst()) // drop "T"

        if typeStr.hasPrefix("@\"") && typeStr.hasSuffix("\"") {
            // Object type: @"NSString" → NSString
            return String(typeStr.dropFirst(2).dropLast())
        }

        // Primitive types
        switch typeStr {
        case "i": return "Int32"
        case "q": return "Int"
        case "Q": return "UInt"
        case "d": return "Double"
        case "f": return "Float"
        case "B": return "Bool"
        case "@": return "id"
        case "v": return "Void"
        case "@?": return "Block"
        default: return typeStr
        }
    }
}
