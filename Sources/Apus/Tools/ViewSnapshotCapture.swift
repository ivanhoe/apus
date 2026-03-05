#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// MCP tool that captures individual snapshots of each view's own layer content.
/// Used for Reveal-style 3D view debugging where each layer plane shows only
/// what that specific view draws (without its children).
final class ViewSnapshotCapture: MCPTool {
    var toolName: String { "get_view_snapshots" }
    var toolDescription: String {
        "Capture each view's own rendering (without children) as individual PNGs. Returns path→base64 map for 3D layer debugging."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "scale": [
                    "type": "number",
                    "description": "Image scale factor (default: 0.5). Lower = smaller images."
                ] as [String: Any],
                "max_depth": [
                    "type": "integer",
                    "description": "Maximum depth to traverse (default: 10)"
                ] as [String: Any],
                "min_size": [
                    "type": "number",
                    "description": "Minimum dimension in points to capture (default: 2)"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let requestedScale = (arguments["scale"] as? NSNumber)?.doubleValue ?? 0.5
        let requestedMaxDepth = (arguments["max_depth"] as? NSNumber)?.intValue ?? 10
        let requestedMinSize = (arguments["min_size"] as? NSNumber)?.doubleValue ?? 2.0

        let scale = sanitizeFinite(requestedScale, defaultValue: 0.5, min: 0.1, max: 3.0)
        let maxDepth = max(0, min(requestedMaxDepth, 20))
        let minSize = sanitizeFinite(requestedMinSize, defaultValue: 2.0, min: 1.0, max: 4096.0)

        return await MainActor.run {
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow })
                    ?? windowScene.windows.first else {
                return MCPToolResult.error("No key window found")
            }

            var snapshots: [String: String] = [:]
            var totalBytes = 0
            var capturedCount = 0
            var skippedCount = 0

            captureSnapshots(
                view: window,
                path: "",
                depth: 0,
                maxDepth: maxDepth,
                scale: CGFloat(scale),
                minSize: CGFloat(minSize),
                snapshots: &snapshots,
                totalBytes: &totalBytes,
                capturedCount: &capturedCount,
                skippedCount: &skippedCount
            )

            let metadata: [String: Any] = [
                "count": capturedCount,
                "skipped": skippedCount,
                "totalSizeKB": totalBytes / 1024,
                "scale": scale
            ]

            let result: [String: Any] = [
                "snapshots": snapshots,
                "metadata": metadata
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return MCPToolResult.error("Failed to serialize snapshots")
            }

            return MCPToolResult.text(jsonString)
        }
    }

    private func sanitizeFinite(_ value: Double, defaultValue: Double, min: Double, max: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        if value < min { return min }
        if value > max { return max }
        return value
    }

    @MainActor
    private func captureSnapshots(
        view: UIView,
        path: String,
        depth: Int,
        maxDepth: Int,
        scale: CGFloat,
        minSize: CGFloat,
        snapshots: inout [String: String],
        totalBytes: inout Int,
        capturedCount: inout Int,
        skippedCount: inout Int
    ) {
        guard depth <= maxDepth else { return }
        guard !view.isHidden && view.alpha > 0.01 else { return }

        let frame = view.frame
        guard frame.width >= minSize && frame.height >= minSize else { return }

        if let pngData = renderLayerOnly(view: view, scale: scale) {
            // Skip trivially small PNGs (fully transparent renders compress to < 200 bytes)
            if pngData.count > 200 {
                let key = path.isEmpty ? "root" : path
                snapshots[key] = pngData.base64EncodedString()
                totalBytes += pngData.count
                capturedCount += 1
            } else {
                skippedCount += 1
            }
        } else {
            skippedCount += 1
        }

        for (index, subview) in view.subviews.enumerated() {
            let childPath = path.isEmpty ? "\(index)" : "\(path).\(index)"
            captureSnapshots(
                view: subview,
                path: childPath,
                depth: depth + 1,
                maxDepth: maxDepth,
                scale: scale,
                minSize: minSize,
                snapshots: &snapshots,
                totalBytes: &totalBytes,
                capturedCount: &capturedCount,
                skippedCount: &skippedCount
            )
        }
    }

    /// Renders a view's layer WITHOUT its sublayers, capturing only what
    /// this specific view draws (background, content, border, shadow).
    @MainActor
    private func renderLayerOnly(view: UIView, scale: CGFloat) -> Data? {
        let layer = view.layer
        let bounds = layer.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return nil }

        // Temporarily hide sublayers (safer than removing/re-adding)
        let sublayers = layer.sublayers ?? []
        let savedHidden = sublayers.map { $0.isHidden }
        sublayers.forEach { $0.isHidden = true }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: bounds.size, format: format)
        let image = renderer.image { ctx in
            layer.render(in: ctx.cgContext)
        }

        // Restore sublayer visibility
        for (i, sublayer) in sublayers.enumerated() {
            sublayer.isHidden = savedHidden[i]
        }

        return image.pngData()
    }
}
#endif
