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
    private let projectRootProvider: () -> String?

    init(projectRootProvider: @escaping () -> String? = { nil }) {
        self.projectRootProvider = projectRootProvider
    }

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
        - Changes that declare class/actor/protocol or @main are rejected (use preview_changes/build+deploy)
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
        let originalPath = arguments["original_path"] as? String

        guard sourceCode != nil || dylibPathArg != nil else {
            return .error("Provide either source_code or dylib_path")
        }

        let dylibPath: String

        if let sourceCode {
            let sourceValidation = HotReloadSourceValidator.validate(
                sourceCode: sourceCode,
                originalPath: originalPath
            )
            if !sourceValidation.isInjectable {
                return .error(
                    HotReloadSourceValidator.formatRejectionMessage(
                        validation: sourceValidation,
                        originalPath: originalPath
                    )
                )
            }

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

    private struct BuildToolchainHint {
        let developerDir: String?
        let swiftVersion: String?
    }

    private struct PreferredSDKInfo {
        let path: String?
        let version: String?
    }

    /// Compiles Swift source code into a dylib for injection.
    ///
    /// Auto-detects paths using `#filePath` to find the package root, then searches
    /// for build products (Apus.swiftmodule) in common locations.
    private func compileSource(_ sourceCode: String) -> CompilationResult {
        // 1. Auto-detect paths
        let appName = Bundle.main.infoDictionary?["CFBundleName"] as? String
            ?? (Bundle.main.bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

        let packageRoot = HotReloadBuildProductsLocator.packageRootFromFilePath(#filePath)
        let projectRoot = projectRootProvider()
        let resolution = HotReloadBuildProductsLocator.resolve(
            appName: appName,
            projectRoot: projectRoot,
            packageRoot: packageRoot
        )

        guard let buildProductsDir = resolution.foundPath else {
            let checkedPaths = resolution.searchedPaths
                .prefix(12)
                .map { "  - \($0)" }
                .joined(separator: "\n")

            var message = "Could not find build products directory. Searched near: \(packageRoot)\n"
            if !checkedPaths.isEmpty {
                message += "Checked paths:\n\(checkedPaths)\n"
            }
            message += "Ensure you've built the app with xcodebuild before using source_code mode."
            return .failure(message)
        }

        // Derive intermediates dir (sibling of Products/)
        // buildProductsDir = .../Build/Products/Debug-iphonesimulator
        let buildDir = ((buildProductsDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let intermediatesDir = buildDir + "/Intermediates.noindex"

        // Resolve swiftc and SDK paths.
        // Prefer the same Xcode install that built Apus.swiftmodule to avoid
        // module format mismatches (e.g. Swift 6.2 vs 6.2.4).
        let sdkName = detectSDKName(fromBuildProductsDir: buildProductsDir)
        let toolchainHint = buildToolchainHint(fromBuildProductsDir: buildProductsDir)
        let xcrunPrefix = scopedXcrunPrefix(fromDeveloperDir: toolchainHint.developerDir)

        let swiftcPath: String
        if let preferredSwiftc = preferredSwiftcPath(fromDeveloperDir: toolchainHint.developerDir) {
            swiftcPath = preferredSwiftc
        } else {
            let (resolvedSwiftcPath, swiftcExit) = shellOutput("\(xcrunPrefix) --find swiftc")
            guard swiftcExit == 0, !resolvedSwiftcPath.isEmpty else {
                return .failure("Failed to find swiftc via xcrun: \(resolvedSwiftcPath)")
            }
            swiftcPath = resolvedSwiftcPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let preferredSDK = preferredSDKInfo(fromDeveloperDir: toolchainHint.developerDir, sdkName: sdkName)

        let sdkPath: String
        if let preferredSDKPath = preferredSDK.path {
            sdkPath = preferredSDKPath
        } else {
            let (resolvedSDKPath, sdkExit) = shellOutput("\(xcrunPrefix) --show-sdk-path --sdk \(shellEscape(sdkName))")
            guard sdkExit == 0, !resolvedSDKPath.isEmpty else {
                return .failure("Failed to find SDK path via xcrun: \(resolvedSDKPath)")
            }
            sdkPath = resolvedSDKPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let sdkVersion: String
        if let preferredSDKVersion = preferredSDK.version {
            sdkVersion = preferredSDKVersion
        } else {
            let (resolvedSDKVersion, sdkVersionExit) = shellOutput("\(xcrunPrefix) --show-sdk-version --sdk \(shellEscape(sdkName))")
            guard sdkVersionExit == 0, !resolvedSDKVersion.isEmpty else {
                return .failure("Failed to find SDK version via xcrun: \(resolvedSDKVersion)")
            }
            sdkVersion = resolvedSDKVersion.trimmingCharacters(in: .whitespacesAndNewlines)
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
            sdkVersion: sdkVersion
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
            "-sdk", sdkPath,
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
            let compilerOutput = output.isEmpty ? "swiftc exited with code \(exitCode)" : output
            let toolchainContext = formatToolchainContext(hint: toolchainHint, swiftcPath: swiftcPath)
            let combinedOutput = toolchainContext.isEmpty ? compilerOutput : "\(compilerOutput)\n\n\(toolchainContext)"
            return .failure(combinedOutput)
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

    private func scopedXcrunPrefix(fromDeveloperDir developerDir: String?) -> String {
        guard let developerDir, !developerDir.isEmpty else {
            return "/usr/bin/xcrun"
        }
        return "DEVELOPER_DIR=\(shellEscape(developerDir)) /usr/bin/xcrun"
    }

    private func preferredSwiftcPath(fromDeveloperDir developerDir: String?) -> String? {
        guard let developerDir, !developerDir.isEmpty else {
            return nil
        }

        let swiftcPath = "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        guard FileManager.default.fileExists(atPath: swiftcPath) else {
            return nil
        }

        return swiftcPath
    }

    private func preferredSDKInfo(fromDeveloperDir developerDir: String?, sdkName: String) -> PreferredSDKInfo {
        guard let developerDir, !developerDir.isEmpty,
              let sdkLayout = sdkLayout(for: sdkName) else {
            return PreferredSDKInfo(path: nil, version: nil)
        }

        let sdkDir = "\(developerDir)/\(sdkLayout.directory)"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: sdkDir) else {
            return PreferredSDKInfo(path: nil, version: nil)
        }

        // Prefer explicit versioned SDK directories/symlinks (e.g. iPhoneSimulator26.0.sdk)
        // so target triples match the build that produced Apus.swiftmodule.
        let versionedCandidates = entries
            .compactMap { entry -> (entry: String, version: String)? in
                guard let version = parseSDKVersion(fromEntry: entry, baseName: sdkLayout.baseName) else {
                    return nil
                }
                return (entry, version)
            }
            .sorted {
                $0.version.compare($1.version, options: .numeric) == .orderedDescending
            }

        if let selected = versionedCandidates.first {
            let path = "\(sdkDir)/\(selected.entry)"
            return PreferredSDKInfo(path: path, version: selected.version)
        }

        // Fall back to unversioned SDK path if it exists.
        let unversionedPath = "\(sdkDir)/\(sdkLayout.baseName).sdk"
        if fm.fileExists(atPath: unversionedPath) {
            return PreferredSDKInfo(path: unversionedPath, version: nil)
        }

        return PreferredSDKInfo(path: nil, version: nil)
    }

    private func sdkLayout(for sdkName: String) -> (directory: String, baseName: String)? {
        switch sdkName {
        case "iphonesimulator":
            return ("Platforms/iPhoneSimulator.platform/Developer/SDKs", "iPhoneSimulator")
        case "iphoneos":
            return ("Platforms/iPhoneOS.platform/Developer/SDKs", "iPhoneOS")
        case "macosx":
            return ("Platforms/MacOSX.platform/Developer/SDKs", "MacOSX")
        default:
            return nil
        }
    }

    private func parseSDKVersion(fromEntry entry: String, baseName: String) -> String? {
        guard entry.hasPrefix(baseName), entry.hasSuffix(".sdk") else {
            return nil
        }

        let start = entry.index(entry.startIndex, offsetBy: baseName.count)
        let end = entry.index(entry.endIndex, offsetBy: -4) // remove ".sdk"
        guard start < end else {
            return nil
        }

        let version = String(entry[start..<end])
        guard !version.isEmpty else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "0123456789.")
        let invalidRange = version.rangeOfCharacter(from: allowed.inverted)
        return invalidRange == nil ? version : nil
    }

    private func buildToolchainHint(fromBuildProductsDir buildProductsDir: String) -> BuildToolchainHint {
        guard let swiftmodulePath = findApusSwiftmoduleBinaryPath(inBuildProductsDir: buildProductsDir) else {
            return BuildToolchainHint(developerDir: nil, swiftVersion: nil)
        }

        let (output, exitCode) = shellOutput("/usr/bin/strings -n 8 \(shellEscape(swiftmodulePath))")
        guard exitCode == 0, !output.isEmpty else {
            return BuildToolchainHint(developerDir: nil, swiftVersion: nil)
        }

        return BuildToolchainHint(
            developerDir: extractDeveloperDir(fromStringsOutput: output),
            swiftVersion: extractSwiftVersion(fromStringsOutput: output)
        )
    }

    private func findApusSwiftmoduleBinaryPath(inBuildProductsDir buildProductsDir: String) -> String? {
        let moduleDir = buildProductsDir + "/Apus.swiftmodule"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: moduleDir) else {
            return nil
        }

        guard let filename = entries.sorted().first(where: { $0.hasSuffix(".swiftmodule") }) else {
            return nil
        }

        return moduleDir + "/" + filename
    }

    private func extractDeveloperDir(fromStringsOutput output: String) -> String? {
        // Example match:
        // /Applications/Xcode-26.0.1.app/Contents/Developer/...
        let pattern = #"/Applications/[^\s]+\.app/Contents/Developer"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: nsRange),
              let range = Range(match.range, in: output) else {
            return nil
        }

        return String(output[range])
    }

    private func extractSwiftVersion(fromStringsOutput output: String) -> String? {
        output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("Apple Swift version") })
    }

    private func formatToolchainContext(hint: BuildToolchainHint, swiftcPath: String) -> String {
        var lines: [String] = []
        let trimmedSwiftcPath = swiftcPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSwiftcPath.isEmpty {
            lines.append("Toolchain context:")
            lines.append("  swiftc: \(trimmedSwiftcPath)")
        }
        if let developerDir = hint.developerDir, !developerDir.isEmpty {
            if lines.isEmpty { lines.append("Toolchain context:") }
            lines.append("  developerDir: \(developerDir)")
        }
        if let swiftVersion = hint.swiftVersion, !swiftVersion.isEmpty {
            if lines.isEmpty { lines.append("Toolchain context:") }
            lines.append("  moduleBuiltWith: \(swiftVersion)")
        }
        return lines.joined(separator: "\n")
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
