import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// MCP tool that inspects the app's view hierarchy.
final class ViewHierarchyInspector: MCPTool {
    var toolName: String { "get_view_hierarchy" }
    var toolDescription: String {
        "UIKit view tree: types, frames, properties. For layout; use get_screenshot for visual."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "depth": [
                    "type": "integer",
                    "description": "Maximum depth to traverse (default: 5)"
                ],
                "include_hidden": [
                    "type": "boolean",
                    "description": "Include hidden views (default: false)"
                ],
                "format": [
                    "type": "string",
                    "enum": ["text", "json"],
                    "description": "Output format: 'text' (default) or 'json' (structured)"
                ]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        #if canImport(UIKit) && !os(watchOS)
        let depth = arguments["depth"] as? Int ?? 5
        let includeHidden = arguments["include_hidden"] as? Bool ?? false
        let format = arguments["format"] as? String ?? "text"

        return await MainActor.run {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow })
                    ?? windowScene.windows.first else {
                return MCPToolResult.error("No window found")
            }

            if format == "json" {
                let json = inspectViewJSON(window, depth: 0, maxDepth: depth, includeHidden: includeHidden)
                guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                      let jsonString = String(data: data, encoding: .utf8) else {
                    return MCPToolResult.error("Failed to serialize view hierarchy to JSON")
                }
                return MCPToolResult.text(jsonString)
            }

            let hierarchy = inspectView(window, depth: 0, maxDepth: depth, includeHidden: includeHidden)
            return MCPToolResult.text("View Hierarchy:\n\n\(hierarchy)")
        }
        #else
        return .error("View hierarchy inspection is only available on iOS/tvOS")
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    // MARK: - Text format

    @MainActor
    private func inspectView(_ view: UIView, depth: Int, maxDepth: Int, includeHidden: Bool) -> String {
        if depth >= maxDepth { return "" }
        if !includeHidden && view.isHidden { return "" }

        let indent = String(repeating: "  ", count: depth)
        let typeName = String(describing: type(of: view))
        let frame = view.frame
        let frameStr = String(format: "(%.0f, %.0f, %.0f, %.0f)",
                              frame.origin.x, frame.origin.y,
                              frame.size.width, frame.size.height)

        var props: [String] = []

        if view.isHidden { props.append("hidden") }
        if view.alpha < 1.0 { props.append(String(format: "alpha=%.2f", view.alpha)) }
        if !view.isUserInteractionEnabled { props.append("interaction=off") }
        if let a11yLabel = view.accessibilityLabel { props.append("a11y=\"\(a11yLabel)\"") }
        if let a11yId = view.accessibilityIdentifier { props.append("id=\"\(a11yId)\"") }

        // Extract useful text/content properties from common UIKit views
        extractViewProperties(view, into: &props)

        let propsStr = props.isEmpty ? "" : " [\(props.joined(separator: ", "))]"
        var result = "\(indent)\(typeName) \(frameStr)\(propsStr)\n"

        for subview in view.subviews {
            result += inspectView(subview, depth: depth + 1, maxDepth: maxDepth, includeHidden: includeHidden)
        }

        return result
    }

    @MainActor
    private func extractViewProperties(_ view: UIView, into props: inout [String]) {
        if let label = view as? UILabel, let text = label.text, !text.isEmpty {
            props.append("text=\"\(text.prefix(60))\"")
        }
        if let button = view as? UIButton, let title = button.titleLabel?.text, !title.isEmpty {
            props.append("title=\"\(title.prefix(60))\"")
        }
        if let textField = view as? UITextField {
            if let text = textField.text, !text.isEmpty {
                props.append("text=\"\(text.prefix(60))\"")
            }
            if let placeholder = textField.placeholder {
                props.append("placeholder=\"\(placeholder.prefix(60))\"")
            }
        }
        if let textView = view as? UITextView, let text = textView.text, !text.isEmpty {
            props.append("text=\"\(text.prefix(60))\"")
        }
        if let imageView = view as? UIImageView {
            props.append("hasImage=\(imageView.image != nil)")
        }
        if let scrollView = view as? UIScrollView {
            let offset = scrollView.contentOffset
            let size = scrollView.contentSize
            props.append(String(format: "contentOffset=(%.0f,%.0f)", offset.x, offset.y))
            props.append(String(format: "contentSize=(%.0f,%.0f)", size.width, size.height))
        }
        if let tableView = view as? UITableView {
            props.append("sections=\(tableView.numberOfSections)")
        }
    }

    // MARK: - JSON format

    @MainActor
    private func inspectViewJSON(_ view: UIView, depth: Int, maxDepth: Int, includeHidden: Bool, path: String = "") -> [String: Any] {
        let fullClassName = NSStringFromClass(type(of: view))
        let className = String(describing: type(of: view))

        // Extract module name from full class name (e.g. "MyApp.MyView" → "MyApp")
        let moduleName: String
        if let dotIndex = fullClassName.firstIndex(of: ".") {
            moduleName = String(fullClassName[fullClassName.startIndex..<dotIndex])
            // Handle underscore-prefixed names like "_TtC5MyApp6MyView"
        } else {
            moduleName = "UIKit"
        }

        let frame = view.frame

        var properties: [String: Any] = [
            "hidden": view.isHidden,
            "alpha": Double(view.alpha),
            "userInteractionEnabled": view.isUserInteractionEnabled,
            "clipsToBounds": view.clipsToBounds,
            "tag": view.tag,
        ]

        if let a11yLabel = view.accessibilityLabel {
            properties["accessibilityLabel"] = a11yLabel
        }
        if let a11yId = view.accessibilityIdentifier {
            properties["accessibilityIdentifier"] = a11yId
        }

        // Type-specific properties
        extractViewPropertiesJSON(view, into: &properties)

        // Stable memory address for this view (useful for debugging)
        let address = "\(Unmanaged.passUnretained(view).toOpaque())"

        var node: [String: Any] = [
            "className": className,
            "fullClassName": fullClassName,
            "moduleName": moduleName,
            "frame": [
                "x": Double(frame.origin.x),
                "y": Double(frame.origin.y),
                "width": Double(frame.size.width),
                "height": Double(frame.size.height),
            ],
            "depth": depth,
            "path": path,
            "address": address,
            "properties": properties,
        ]

        // Recurse into subviews if within depth limit
        if depth < maxDepth {
            var subviewsJSON: [[String: Any]] = []
            for (index, subview) in view.subviews.enumerated() {
                if !includeHidden && subview.isHidden { continue }
                let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
                subviewsJSON.append(inspectViewJSON(subview, depth: depth + 1, maxDepth: maxDepth, includeHidden: includeHidden, path: childPath))
            }
            node["subviews"] = subviewsJSON
        } else {
            node["subviews"] = [] as [[String: Any]]
        }

        return node
    }

    @MainActor
    private func extractViewPropertiesJSON(_ view: UIView, into props: inout [String: Any]) {
        if let label = view as? UILabel {
            props["text"] = label.text
            props["numberOfLines"] = label.numberOfLines
        }
        if let button = view as? UIButton {
            props["title"] = button.titleLabel?.text
        }
        if let textField = view as? UITextField {
            props["text"] = textField.text
            props["placeholder"] = textField.placeholder
        }
        if let textView = view as? UITextView {
            props["text"] = textView.text
        }
        if let imageView = view as? UIImageView {
            props["hasImage"] = imageView.image != nil
            props["contentMode"] = contentModeString(imageView.contentMode)
        }
        if let scrollView = view as? UIScrollView {
            props["contentOffset"] = [
                "x": Double(scrollView.contentOffset.x),
                "y": Double(scrollView.contentOffset.y),
            ]
            props["contentSize"] = [
                "width": Double(scrollView.contentSize.width),
                "height": Double(scrollView.contentSize.height),
            ]
        }
        if let tableView = view as? UITableView {
            props["numberOfSections"] = tableView.numberOfSections
        }
    }

    @MainActor
    private func contentModeString(_ mode: UIView.ContentMode) -> String {
        switch mode {
        case .scaleToFill: return "scaleToFill"
        case .scaleAspectFit: return "scaleAspectFit"
        case .scaleAspectFill: return "scaleAspectFill"
        case .center: return "center"
        case .top: return "top"
        case .bottom: return "bottom"
        case .left: return "left"
        case .right: return "right"
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        case .redraw: return "redraw"
        @unknown default: return "unknown"
        }
    }
    #endif
}
