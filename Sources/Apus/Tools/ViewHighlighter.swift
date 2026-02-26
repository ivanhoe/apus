#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// MCP tool that highlights a view on screen with a colored overlay.
/// Used for visual identification — "which view is this?" — from the inspector.
final class ViewHighlighter: MCPTool {
    var toolName: String { "highlight_view" }
    var toolDescription: String {
        "Highlight a view on screen with a colored border/overlay. Use path from get_view_hierarchy."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "View path from get_view_hierarchy (e.g. '0.0.1.3'). Omit or empty string for the root window."
                ] as [String: Any],
                "color": [
                    "type": "string",
                    "description": "Highlight color as hex (default: '#FF3B30' red). Examples: '#007AFF' blue, '#34C759' green."
                ] as [String: Any],
                "duration": [
                    "type": "number",
                    "description": "How long to show the highlight in seconds (default: 2.0)"
                ] as [String: Any]
            ] as [String: Any],
            "required": [] as [String]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let path = arguments["path"] as? String ?? ""
        let colorHex = arguments["color"] as? String ?? "#FF3B30"
        let duration = arguments["duration"] as? Double ?? 2.0

        return await MainActor.run {
            guard let window = Self.getKeyWindow() else {
                return MCPToolResult.error("No key window found")
            }

            let targetView: UIView
            if path.isEmpty {
                targetView = window
            } else {
                guard let found = Self.findView(at: path, in: window) else {
                    return MCPToolResult.error("View not found at path '\(path)'. Refresh hierarchy and try again.")
                }
                targetView = found
            }

            let color = Self.colorFromHex(colorHex)
            Self.flashHighlight(on: targetView, color: color, duration: duration)

            let className = String(describing: type(of: targetView))
            let frame = targetView.frame
            return MCPToolResult.text("Highlighted \(className) at (\(Int(frame.origin.x)), \(Int(frame.origin.y)), \(Int(frame.size.width)), \(Int(frame.size.height))) for \(duration)s")
        }
    }

    // MARK: - View Finding

    @MainActor
    static func getKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
            .flatMap { $0.windows.first(where: { $0.isKeyWindow }) ?? $0.windows.first }
    }

    /// Find a view by its index path (e.g. "0.1.3" = window.subviews[0].subviews[1].subviews[3])
    @MainActor
    static func findView(at path: String, in window: UIWindow) -> UIView? {
        let indices = path.split(separator: ".").compactMap { Int($0) }
        guard !indices.isEmpty else { return nil }

        var current: UIView = window
        for index in indices {
            guard index >= 0, index < current.subviews.count else { return nil }
            current = current.subviews[index]
        }
        return current
    }

    // MARK: - Highlight Animation

    @MainActor
    private static func flashHighlight(on view: UIView, color: UIColor, duration: Double) {
        // Remove any existing highlight overlays on this view
        view.subviews
            .filter { $0.tag == 98765 }
            .forEach { $0.removeFromSuperview() }

        let overlay = UIView(frame: view.bounds)
        overlay.tag = 98765
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = color.withAlphaComponent(0.15)
        overlay.layer.borderColor = color.cgColor
        overlay.layer.borderWidth = 2.0
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)

        // Pulse animation then fade out
        UIView.animate(withDuration: 0.2, delay: 0, options: [.autoreverse, .repeat], animations: {
            UIView.setAnimationRepeatCount(2)
            overlay.backgroundColor = color.withAlphaComponent(0.3)
        }, completion: { _ in
            UIView.animate(withDuration: 0.5, delay: max(0, duration - 0.9), options: [], animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        })
    }

    // MARK: - Color Parsing

    static func colorFromHex(_ hex: String) -> UIColor {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }

        guard hexStr.count == 6,
              let rgb = UInt64(hexStr, radix: 16) else {
            return .systemRed
        }

        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
