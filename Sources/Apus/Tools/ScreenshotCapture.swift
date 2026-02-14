#if canImport(UIKit) && !os(watchOS)
import UIKit
import Foundation

/// MCP tool that captures a screenshot of the app's current screen.
/// Returns the image as PNG data that AI agents can see and analyze.
final class ScreenshotCapture: MCPTool {
    var toolName: String { "get_screenshot" }
    var toolDescription: String {
        "Capture a screenshot of the app's current screen. Returns a PNG image that you can see and analyze to understand the current UI state."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "scale": [
                    "type": "number",
                    "description": "Image scale factor (default: 1.0 for 1x, use 2.0 for retina). Lower values produce smaller images."
                ] as [String: Any],
                "window_index": [
                    "type": "integer",
                    "description": "Window index to capture (default: 0 for the key window)"
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let scale = arguments["scale"] as? Double ?? 1.0
        let windowIndex = arguments["window_index"] as? Int ?? 0

        // Must capture on the main thread (UIKit requirement)
        let result: Result<Data, ScreenshotError> = await MainActor.run {
            captureScreen(scale: CGFloat(scale), windowIndex: windowIndex)
        }

        switch result {
        case .success(let pngData):
            let kb = pngData.count / 1024
            return MCPToolResult(content: [
                .text("Screenshot captured (\(kb) KB, scale: \(scale)x)"),
                .image(data: pngData, mimeType: "image/png")
            ])
        case .failure(let error):
            return .error(error.message)
        }
    }

    @MainActor
    private func captureScreen(scale: CGFloat, windowIndex: Int) -> Result<Data, ScreenshotError> {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        guard let scene = scenes.first else {
            return .failure(.noScene)
        }

        let windows = scene.windows.filter { !$0.isHidden }

        guard !windows.isEmpty else {
            return .failure(.noWindows)
        }

        let window: UIWindow
        if windowIndex < windows.count {
            window = windows[windowIndex]
        } else {
            window = windows[0]
        }

        let renderer = UIGraphicsImageRenderer(
            size: window.bounds.size,
            format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale
                return format
            }()
        )

        let image = renderer.image { context in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }

        guard let pngData = image.pngData() else {
            return .failure(.encodingFailed)
        }

        return .success(pngData)
    }
}

private enum ScreenshotError: Error {
    case noScene
    case noWindows
    case encodingFailed

    var message: String {
        switch self {
        case .noScene: return "No active UIWindowScene found. Is the app in the foreground?"
        case .noWindows: return "No visible windows found."
        case .encodingFailed: return "Failed to encode screenshot as PNG."
        }
    }
}
#endif
