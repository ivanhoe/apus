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
                ]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        #if canImport(UIKit) && !os(watchOS)
        let depth = arguments["depth"] as? Int ?? 5
        let includeHidden = arguments["include_hidden"] as? Bool ?? false

        return await MainActor.run {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow })
                    ?? windowScene.windows.first else {
                return MCPToolResult.error("No window found")
            }

            let hierarchy = inspectView(window, depth: 0, maxDepth: depth, includeHidden: includeHidden)
            return MCPToolResult.text("View Hierarchy:\n\n\(hierarchy)")
        }
        #else
        return .error("View hierarchy inspection is only available on iOS/tvOS")
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
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
    #endif
}
