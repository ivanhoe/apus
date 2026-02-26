#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// MCP tool that modifies view properties at runtime.
/// Enables live visual debugging — change colors, visibility, frames without recompiling.
final class ViewPropertyEditor: MCPTool {
    var toolName: String { "modify_view" }
    var toolDescription: String {
        "Modify view properties at runtime: backgroundColor, alpha, hidden, frame, border, cornerRadius."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "View path from get_view_hierarchy (e.g. '0.0.1.3'). Omit or empty string for the root window."
                ] as [String: Any],
                "backgroundColor": [
                    "type": "string",
                    "description": "Background color as hex (e.g. '#FF0000'). Use 'clear' for transparent."
                ] as [String: Any],
                "alpha": [
                    "type": "number",
                    "description": "Opacity 0.0 to 1.0"
                ] as [String: Any],
                "hidden": [
                    "type": "boolean",
                    "description": "Whether the view is hidden"
                ] as [String: Any],
                "borderColor": [
                    "type": "string",
                    "description": "Border color as hex"
                ] as [String: Any],
                "borderWidth": [
                    "type": "number",
                    "description": "Border width in points"
                ] as [String: Any],
                "cornerRadius": [
                    "type": "number",
                    "description": "Corner radius in points"
                ] as [String: Any],
                "frame": [
                    "type": "object",
                    "description": "New frame: {x, y, width, height}. Only provided fields are changed.",
                    "properties": [
                        "x": ["type": "number"] as [String: Any],
                        "y": ["type": "number"] as [String: Any],
                        "width": ["type": "number"] as [String: Any],
                        "height": ["type": "number"] as [String: Any],
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": [] as [String]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let path = arguments["path"] as? String ?? ""

        return await MainActor.run {
            guard let window = ViewHighlighter.getKeyWindow() else {
                return MCPToolResult.error("No key window found")
            }

            let targetView: UIView
            if path.isEmpty {
                targetView = window
            } else {
                guard let found = ViewHighlighter.findView(at: path, in: window) else {
                    return MCPToolResult.error("View not found at path '\(path)'. Refresh hierarchy and try again.")
                }
                targetView = found
            }

            var changes: [String] = []

            // backgroundColor
            if let bgHex = arguments["backgroundColor"] as? String {
                if bgHex.lowercased() == "clear" {
                    targetView.backgroundColor = .clear
                    changes.append("backgroundColor=clear")
                } else {
                    let color = ViewHighlighter.colorFromHex(bgHex)
                    targetView.backgroundColor = color
                    changes.append("backgroundColor=\(bgHex)")
                }
            }

            // alpha
            if let alpha = arguments["alpha"] as? Double {
                let clamped = min(1.0, max(0.0, alpha))
                targetView.alpha = CGFloat(clamped)
                changes.append("alpha=\(clamped)")
            }

            // hidden
            if let hidden = arguments["hidden"] as? Bool {
                targetView.isHidden = hidden
                changes.append("hidden=\(hidden)")
            }

            // borderColor
            if let borderHex = arguments["borderColor"] as? String {
                let color = ViewHighlighter.colorFromHex(borderHex)
                targetView.layer.borderColor = color.cgColor
                changes.append("borderColor=\(borderHex)")
            }

            // borderWidth
            if let borderWidth = arguments["borderWidth"] as? Double {
                targetView.layer.borderWidth = CGFloat(borderWidth)
                changes.append("borderWidth=\(borderWidth)")
            }

            // cornerRadius
            if let cornerRadius = arguments["cornerRadius"] as? Double {
                targetView.layer.cornerRadius = CGFloat(cornerRadius)
                targetView.clipsToBounds = true
                changes.append("cornerRadius=\(cornerRadius)")
            }

            // frame (partial update)
            if let frameDict = arguments["frame"] as? [String: Any] {
                var frame = targetView.frame
                if let x = frameDict["x"] as? Double { frame.origin.x = CGFloat(x) }
                if let y = frameDict["y"] as? Double { frame.origin.y = CGFloat(y) }
                if let w = frameDict["width"] as? Double { frame.size.width = CGFloat(w) }
                if let h = frameDict["height"] as? Double { frame.size.height = CGFloat(h) }
                targetView.frame = frame
                changes.append("frame=(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height)))")
            }

            if changes.isEmpty {
                return MCPToolResult.error("No properties specified to modify. Provide at least one of: backgroundColor, alpha, hidden, borderColor, borderWidth, cornerRadius, frame.")
            }

            let className = String(describing: type(of: targetView))
            return MCPToolResult.text("Modified \(className) at path '\(path)': \(changes.joined(separator: ", "))")
        }
    }
}
#endif
