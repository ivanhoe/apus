#if DEBUG
import Foundation
import CHotReload

/// MCP tool that hot-reloads a compiled dylib into the running app.
///
/// Workflow:
/// 1. Claude Code edits a Swift file and compiles it to a dylib via `swiftc -emit-library`
/// 2. This tool loads the dylib via `dlopen`
/// 3. fishhook rebinds all exported symbols from the dylib into the running process
/// 4. Posts `INJECTION_BUNDLE_NOTIFICATION` so SwiftUI views with `@ObserveInjection` re-render
///
/// Requires the app to be linked with `-Xlinker -interposable`.
/// Only works in the simulator (device code signing prevents dlopen of unsigned code).
final class HotReloadTool: MCPTool {
    var toolName: String { "hot_reload" }

    var toolDescription: String {
        "Load a compiled dylib into the running app for hot reload. " +
        "The dylib must be in /tmp/. After loading, uses fishhook to rebind " +
        "symbols and posts INJECTION_BUNDLE_NOTIFICATION so SwiftUI views " +
        "with @ObserveInjection re-render. Simulator only. " +
        "App must be linked with -Xlinker -interposable."
    }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "dylib_path": [
                    "type": "string",
                    "description": "Absolute path to the compiled .dylib file (must be in /tmp/)"
                ] as [String: Any]
            ] as [String: Any],
            "required": ["dylib_path"]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let dylibPath = arguments["dylib_path"] as? String else {
            return .error("Missing required parameter: dylib_path")
        }

        // Security: only allow loading from /tmp/
        guard dylibPath.hasPrefix("/tmp/") else {
            return .error("Security: dylib_path must be in /tmp/. Got: \(dylibPath)")
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dylibPath) else {
            return .error("File not found: \(dylibPath)")
        }

        // Copy to a unique path to avoid dlopen caching
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let uniquePath = "/tmp/injection_\(timestamp).dylib"

        do {
            try fileManager.copyItem(atPath: dylibPath, toPath: uniquePath)
        } catch {
            return .error("Failed to copy dylib: \(error.localizedDescription)")
        }

        // Load the dylib
        guard dlopen(uniquePath, RTLD_NOW) != nil else {
            let errorMessage = String(cString: dlerror())
            try? fileManager.removeItem(atPath: uniquePath)
            return .error("dlopen failed: \(errorMessage)")
        }

        // Rebind symbols from the new dylib into all loaded images
        let rebound = hot_reload_interpose(uniquePath)

        // Notify SwiftUI views to re-render
        await MainActor.run {
            NotificationCenter.default.post(
                name: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"),
                object: nil
            )
        }

        if rebound >= 0 {
            return .text("Hot reload successful. Loaded: \(uniquePath) (\(rebound) symbols rebound)")
        } else {
            return .text("Hot reload: dylib loaded but symbol interposition failed. " +
                        "Ensure the app was linked with -Xlinker -interposable. " +
                        "Loaded: \(uniquePath)")
        }
    }
}
#endif
