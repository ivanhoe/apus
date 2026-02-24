#if DEBUG
import Foundation
import CHotReload

/// MCP tool that hot-reloads Swift source code or a compiled dylib into the running app.
///
/// Two modes:
/// - **source_code mode** (preferred): Pass Swift source directly, the tool compiles and injects it.
/// - **dylib_path mode** (legacy): Pass a precompiled dylib path.
///
/// After injection, fishhook rebinds exported symbols and posts `INJECTION_BUNDLE_NOTIFICATION`
/// so SwiftUI views with `@ObserveInjection` re-render.
///
/// Requires the app to be linked with `-Xlinker -interposable`.
/// Only works in the simulator (device code signing prevents dlopen of unsigned code).
final class HotReloadTool: MCPTool {
    var toolName: String { "hot_reload" }

    var toolDescription: String {
        """
        Hot reload a SwiftUI view by passing source_code (Swift source). The tool compiles and injects it automatically, \
        then returns a screenshot showing the result.

        WORKFLOW:
        1. Read the current source file to understand the view structure
        2. Pass the modified structs as source_code — the tool compiles and injects them in ~4 seconds

        WHAT WORKS in source_code:
        - #if DEBUG / #endif directives (compiled with -DDEBUG)
        - @ObserveInjection and .enableInjection() (Apus module is available)
        - import SwiftUI and import Apus
        - Any SwiftUI view struct

        RULES:
        - Include ALL structs that reference each other in one source_code (e.g. if ViewA uses ViewB, include both)
        - Only self-contained structs work — types defined in OTHER files (like app models) are NOT available
        - For simple changes (colors, text, layout), just modify the struct and send it
        - Always start with: import SwiftUI\\n#if DEBUG\\nimport Apus\\n#endif

        EXAMPLE — changing a color from orange to blue:
        source_code: "import SwiftUI\\n#if DEBUG\\nimport Apus\\n#endif\\n\\nstruct MyView: View {\\n    #if DEBUG\\n    \
        @ObserveInjection var forceReload\\n    #endif\\n    var body: some View {\\n        Image(systemName: \\"swift\\")\\n\
                    .foregroundStyle(.blue)\\n        #if DEBUG\\n        .enableInjection()\\n        #endif\\n    }\\n}"
        """
    }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "source_code": [
                    "type": "string",
                    "description": "Complete Swift source code to compile and inject. Must start with imports (SwiftUI, Apus). Include #if DEBUG guards for @ObserveInjection and .enableInjection(). Include ALL structs that depend on each other."
                ] as [String: Any],
                "dylib_path": [
                    "type": "string",
                    "description": "Legacy: absolute path to a precompiled .dylib (must be in /tmp/). Prefer source_code instead."
                ] as [String: Any],
                "include_screenshot": [
                    "type": "boolean",
                    "description": "Return a screenshot after injection (default: true). Set false to skip."
                ] as [String: Any],
                "original_path": [
                    "type": "string",
                    "description": "Path to the original source file (for traceability in the response)."
                ] as [String: Any]
            ] as [String: Any],
            "required": [] as [String]
        ]
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let sourceCode = arguments["source_code"] as? String
        let dylibPathArg = arguments["dylib_path"] as? String

        guard sourceCode != nil || dylibPathArg != nil else {
            return .error("Provide either source_code or dylib_path")
        }

        let dylibPath: String

        if let sourceCode {
            // Inline compilation mode
            switch compileSource(sourceCode) {
            case .success(let compiledPath):
                dylibPath = compiledPath
            case .failure(let compilerOutput):
                return .error("Compilation failed:\n\(compilerOutput)")
            }
        } else if let dylibPathArg {
            // Legacy dylib_path mode — resolve symlinks and .. to prevent path traversal
            let resolvedPath = URL(fileURLWithPath: dylibPathArg)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard resolvedPath.hasPrefix("/tmp/") || resolvedPath.hasPrefix("/private/tmp/") else {
                return .error("Security: dylib_path must be in /tmp/. Got: \(dylibPathArg)")
            }

            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: resolvedPath) else {
                return .error("File not found: \(resolvedPath)")
            }

            dylibPath = resolvedPath
        } else {
            return .error("Provide either source_code or dylib_path")
        }

        let fileManager = FileManager.default

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

        let originalPath = arguments["original_path"] as? String

        var statusMessage: String
        if rebound >= 0 {
            statusMessage = "Hot reload successful. Loaded: \(uniquePath) (\(rebound) symbols rebound)"
        } else {
            statusMessage = "Hot reload: dylib loaded but symbol interposition failed. " +
                        "Ensure the app was linked with -Xlinker -interposable. " +
                        "Loaded: \(uniquePath)"
        }

        if let originalPath {
            statusMessage += "\nSource persisted to: \(originalPath)"
        } else {
            statusMessage += "\nWarning: No original_path provided. Changes are ephemeral and will be lost on app restart. " +
                "Edit the original source file and pass original_path for persistence."
        }

        // Capture screenshot if requested (default: true)
        let includeScreenshot = arguments["include_screenshot"] as? Bool ?? true
        var content: [MCPContent] = [.text(statusMessage)]

        #if canImport(UIKit) && !os(watchOS)
        if includeScreenshot {
            // Brief delay for SwiftUI to re-render
            try await Task.sleep(nanoseconds: 300_000_000)

            let screenshotResult = await MainActor.run {
                ScreenshotCapture.captureScreen(scale: 1.0, windowIndex: 0)
            }
            if case .success(let pngData) = screenshotResult {
                let kb = pngData.count / 1024
                content.append(.text("Screenshot captured (\(kb) KB)"))
                content.append(.image(data: pngData, mimeType: "image/png"))
            }
        }
        #endif

        return MCPToolResult(content: content)
    }

    // MARK: - Inline Compilation

    private enum CompilationResult {
        case success(String)
        case failure(String)
    }

    /// Compiles Swift source code into a dylib for injection.
    ///
    /// Auto-detects paths using `#filePath` to find the package root, then searches
    /// for build products (Apus.swiftmodule) in common locations.
    private func compileSource(_ sourceCode: String) -> CompilationResult {
        // 1. Auto-detect paths
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? (Bundle.main.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

        // Find package root from compile-time source path
        let sourceFilePath: String = #filePath
        // sourceFilePath = .../Sources/Apus/Tools/HotReloadTool.swift
        // Package root = 3 levels up
        var packageRoot = (sourceFilePath as NSString).deletingLastPathComponent // Tools/
        packageRoot = (packageRoot as NSString).deletingLastPathComponent        // Apus/
        packageRoot = (packageRoot as NSString).deletingLastPathComponent        // Sources/
        packageRoot = (packageRoot as NSString).deletingLastPathComponent        // package root

        // Search for build products directory containing Apus.swiftmodule
        guard let buildProductsDir = findBuildProductsDir(packageRoot: packageRoot) else {
            return .failure(
                "Could not find build products directory. Searched near: \(packageRoot)\n" +
                "Ensure you've built the app with xcodebuild before using source_code mode."
            )
        }

        // Derive intermediates dir (sibling of Products/)
        // buildProductsDir = .../Build/Products/Debug-iphonesimulator
        let buildDir = ((buildProductsDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let intermediatesDir = buildDir + "/Intermediates.noindex"

        // Resolve swiftc and SDK paths
        let (swiftcPath, swiftcExit) = shellOutput("/usr/bin/xcrun --find swiftc")
        guard swiftcExit == 0, !swiftcPath.isEmpty else {
            return .failure("Failed to find swiftc via xcrun: \(swiftcPath)")
        }

        let sdkName = detectSDKName(fromBuildProductsDir: buildProductsDir)
        let (sdkPath, sdkExit) = shellOutput("/usr/bin/xcrun --show-sdk-path --sdk \(sdkName)")
        guard sdkExit == 0, !sdkPath.isEmpty else {
            return .failure("Failed to find SDK path via xcrun: \(sdkPath)")
        }
        let (sdkVersion, sdkVersionExit) = shellOutput("/usr/bin/xcrun --show-sdk-version --sdk \(sdkName)")
        guard sdkVersionExit == 0, !sdkVersion.isEmpty else {
            return .failure("Failed to find SDK version via xcrun: \(sdkVersion)")
        }

        // 2. Write source_code to temp file
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let sourcePath = "/tmp/injection_\(timestamp).swift"
        let outputPath = "/tmp/injection_\(timestamp).dylib"

        do {
            try sourceCode.write(toFile: sourcePath, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Failed to write source file: \(error.localizedDescription)")
        }

        // 3. Build swiftc command
        let platformSuffix = detectPlatformSuffix(fromBuildProductsDir: buildProductsDir)
        let targetTriple = buildTargetTriple(
            sdkName: sdkName,
            sdkVersion: sdkVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let moduleMapPath = "\(intermediatesDir)/GeneratedModuleMaps-\(platformSuffix)/CHotReload.modulemap"

        var args = [
            swiftcPath.trimmingCharacters(in: .whitespacesAndNewlines),
            "-emit-library",
            "-o", outputPath,
            "-module-name", appName,
            "-Onone",
            "-DDEBUG",
            "-swift-version", "5",
            "-enable-testing",
            "-enable-bare-slash-regex",
            "-sdk", sdkPath.trimmingCharacters(in: .whitespacesAndNewlines),
            "-target", targetTriple,
            "-module-cache-path", "/tmp/injection_module_cache",
            "-I", buildProductsDir,
            "-F", buildProductsDir,
            "-Xlinker", "-undefined",
            "-Xlinker", "dynamic_lookup",
            sourcePath
        ]

        // Add CHotReload module map if it exists
        if FileManager.default.fileExists(atPath: moduleMapPath) {
            args.insert(contentsOf: [
                "-Xcc", "-fmodule-map-file=\(moduleMapPath)"
            ], at: args.count - 1) // before sourcePath
        }

        let command = args.map(shellEscape).joined(separator: " ")

        // 4. Execute compilation (merge stderr to capture compiler errors)
        let (output, exitCode) = shellOutput(command, mergeStderr: true)

        // Clean up source file
        try? FileManager.default.removeItem(atPath: sourcePath)

        guard exitCode == 0 else {
            return .failure(output.isEmpty ? "swiftc exited with code \(exitCode)" : output)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            return .failure("Compilation succeeded but dylib not found at \(outputPath)")
        }

        return .success(outputPath)
    }

    private func detectPlatformSuffix(fromBuildProductsDir buildProductsDir: String) -> String {
        if buildProductsDir.contains("iphonesimulator") {
            return "iphonesimulator"
        } else if buildProductsDir.contains("iphoneos") {
            return "iphoneos"
        } else {
            return "macosx"
        }
    }

    private func detectSDKName(fromBuildProductsDir buildProductsDir: String) -> String {
        if buildProductsDir.contains("iphoneos") {
            return "iphoneos"
        } else if buildProductsDir.contains("macosx") {
            return "macosx"
        } else {
            return "iphonesimulator"
        }
    }

    private func buildTargetTriple(sdkName: String, sdkVersion: String) -> String {
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #else
        arch = "arm64"
        #endif

        switch sdkName {
        case "iphoneos":
            return "\(arch)-apple-ios\(sdkVersion)"
        case "macosx":
            return "\(arch)-apple-macosx\(sdkVersion)"
        default:
            return "\(arch)-apple-ios\(sdkVersion)-simulator"
        }
    }

    private func shellEscape(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Searches for the build products directory containing Apus.swiftmodule.
    /// Checks common locations relative to the package root.
    private func findBuildProductsDir(packageRoot: String) -> String? {
        let fm = FileManager.default

        // Candidate directories to search for build products
        var candidates: [String] = []

        // 1. ExampleApp/build/ (our standard -derivedDataPath)
        let exampleAppBuild = packageRoot + "/ExampleApp/build/Build/Products"
        // 2. build/ at package root
        let rootBuild = packageRoot + "/build/Build/Products"
        // 3. DerivedData at package root
        let derivedData = packageRoot + "/DerivedData/Build/Products"

        for base in [exampleAppBuild, rootBuild, derivedData] {
            // Try Debug-iphonesimulator first (most common for simulator)
            for config in ["Debug-iphonesimulator", "Debug-iphoneos", "Release-iphonesimulator"] {
                candidates.append(base + "/" + config)
            }
        }

        // 4. Search ~/Library/Developer/Xcode/DerivedData/ for matching projects
        let home = NSHomeDirectory()
        let xcodeDerivedData = home + "/Library/Developer/Xcode/DerivedData"
        if let entries = try? fm.contentsOfDirectory(atPath: xcodeDerivedData) {
            let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
            for entry in entries where entry.hasPrefix(appName) {
                candidates.append(xcodeDerivedData + "/" + entry + "/Build/Products/Debug-iphonesimulator")
            }
        }

        // Return first candidate that contains Apus.swiftmodule
        for candidate in candidates {
            if fm.fileExists(atPath: candidate + "/Apus.swiftmodule") {
                return candidate
            }
        }

        return nil
    }

    /// Executes a shell command via `popen()` and captures its output.
    /// Uses CHotReload's popen wrapper since popen is unavailable from Swift on iOS.
    /// Set `mergeStderr` to true to capture stderr alongside stdout (useful for compiler errors).
    private func shellOutput(_ command: String, mergeStderr: Bool = false) -> (output: String, exitCode: Int32) {
        let fullCommand = mergeStderr ? command + " 2>&1" : command + " 2>/dev/null"

        guard let fp = hot_reload_popen(fullCommand, "r") else {
            return ("Failed to launch popen", -1)
        }

        var output = ""
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while fgets(buffer, Int32(bufferSize), fp) != nil {
            output += String(cString: buffer)
        }

        let status = hot_reload_pclose(fp)
        // pclose returns the exit status in the same format as waitpid
        let exitCode = (status >> 8) & 0xFF

        return (output, Int32(exitCode))
    }
}
#endif
