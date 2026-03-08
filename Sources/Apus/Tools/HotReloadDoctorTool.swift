#if DEBUG
import Foundation

/// MCP tool that validates whether hot reload can run reliably in the current runtime.
/// Returns structured JSON with status, checks, reason codes, and recommended execution path.
final class HotReloadDoctorTool: MCPTool {
    var toolName: String { "hot_reload_doctor" }
    var toolDescription: String {
        "Validate hot reload readiness (debug/simulator/build artifacts/interposable hints) and recommend hot_reload or preview_changes."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "source_code": [
                    "type": "string",
                    "description": "Optional Swift source to validate hot-reload injectability for this specific edit."
                ] as [String: Any],
                "original_path": [
                    "type": "string",
                    "description": "Optional project-relative file path for source_code (used in validation context)."
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    struct BuildProductsProbe {
        let foundPath: String?
        let searchedPaths: [String]
        let hasApusSwiftmodule: Bool
    }

    struct InterposableProbe {
        let detected: Bool
        let evidence: String
    }

    private struct CheckResult {
        let id: String
        let title: String
        let ok: Bool
        let blocking: Bool
        let details: String
        let reasonCode: String?

        func asJSON() -> [String: Any] {
            var json: [String: Any] = [
                "id": id,
                "title": title,
                "ok": ok,
                "blocking": blocking,
                "details": details
            ]
            if let reasonCode {
                json["reason_code"] = reasonCode
            }
            return json
        }
    }

    private let toolRegistry: ToolRegistry
    private let projectRootProvider: () -> String?
    private let appNameProvider: () -> String
    private let isDebugBuild: Bool
    private let isSimulator: Bool
    private let buildProductsProbe: (_ appName: String, _ projectRoot: String?) -> BuildProductsProbe
    private let interposableProbe: (_ projectRoot: String?) -> InterposableProbe

    init(
        toolRegistry: ToolRegistry,
        projectRootProvider: @escaping () -> String? = { nil },
        appNameProvider: @escaping () -> String = {
            let bundle = Bundle.main
            return bundle.infoDictionary?["CFBundleName"] as? String
                ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.bundleIdentifier
                ?? "UnknownApp"
        },
        isDebugBuild: Bool = {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }(),
        isSimulator: Bool = {
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }(),
        buildProductsProbe: @escaping (_ appName: String, _ projectRoot: String?) -> BuildProductsProbe = HotReloadDoctorTool.defaultBuildProductsProbe,
        interposableProbe: @escaping (_ projectRoot: String?) -> InterposableProbe = HotReloadDoctorTool.defaultInterposableProbe
    ) {
        self.toolRegistry = toolRegistry
        self.projectRootProvider = projectRootProvider
        self.appNameProvider = appNameProvider
        self.isDebugBuild = isDebugBuild
        self.isSimulator = isSimulator
        self.buildProductsProbe = buildProductsProbe
        self.interposableProbe = interposableProbe
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let appName = appNameProvider()
        let projectRoot = projectRootProvider()
        let sourceCode = arguments["source_code"] as? String
        let originalPath = arguments["original_path"] as? String
        let buildProbe = buildProductsProbe(appName, projectRoot)
        let interposeProbe = interposableProbe(projectRoot)

        let hasHotReloadTool = toolRegistry
            .toolsList()
            .contains { ($0["name"] as? String) == "hot_reload" }

        var checks: [CheckResult] = []

        checks.append(CheckResult(
            id: "is_debug",
            title: "Debug Build",
            ok: isDebugBuild,
            blocking: true,
            details: isDebugBuild ? "Running in DEBUG configuration." : "Hot reload requires DEBUG build.",
            reasonCode: isDebugBuild ? nil : "HR_NOT_DEBUG"
        ))

        checks.append(CheckResult(
            id: "is_simulator",
            title: "Simulator Runtime",
            ok: isSimulator,
            blocking: true,
            details: isSimulator ? "Running on simulator." : "Hot reload requires simulator runtime.",
            reasonCode: isSimulator ? nil : "HR_NOT_SIMULATOR"
        ))

        checks.append(CheckResult(
            id: "hot_reload_tool_registered",
            title: "hot_reload Tool Registration",
            ok: hasHotReloadTool,
            blocking: true,
            details: hasHotReloadTool ? "hot_reload tool is registered." : "hot_reload tool is not registered.",
            reasonCode: hasHotReloadTool ? nil : "HR_HOT_RELOAD_TOOL_MISSING"
        ))

        checks.append(CheckResult(
            id: "project_root_detected",
            title: "Project Root Detection",
            ok: projectRoot != nil,
            blocking: false,
            details: projectRoot.map { "Detected project root: \($0)" } ?? "Project root is unavailable.",
            reasonCode: projectRoot == nil ? "HR_PROJECT_ROOT_UNDETECTED" : nil
        ))

        checks.append(CheckResult(
            id: "build_products_found",
            title: "Build Products Availability",
            ok: buildProbe.foundPath != nil,
            blocking: true,
            details: buildProbe.foundPath.map { "Found build products at: \($0)" }
                ?? "No candidate build products found.",
            reasonCode: buildProbe.foundPath == nil ? "HR_BUILD_PRODUCTS_MISSING" : nil
        ))

        checks.append(CheckResult(
            id: "apus_swiftmodule_found",
            title: "Apus.swiftmodule Presence",
            ok: buildProbe.hasApusSwiftmodule,
            blocking: false,
            details: buildProbe.hasApusSwiftmodule
                ? "Apus.swiftmodule detected in build products."
                : "Apus.swiftmodule not detected in located build products.",
            reasonCode: buildProbe.hasApusSwiftmodule ? nil : "HR_APUS_SWIFTMODULE_MISSING"
        ))

        checks.append(CheckResult(
            id: "interposable_hint",
            title: "Interposable Linker Hint",
            ok: interposeProbe.detected,
            blocking: false,
            details: interposeProbe.evidence,
            reasonCode: interposeProbe.detected ? nil : "HR_INTERPOSABLE_NOT_DETECTED"
        ))

        var extraReasonCodes: [String] = []
        if let sourceCode, !sourceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let validation = HotReloadSourceValidator.validate(
                sourceCode: sourceCode,
                originalPath: originalPath
            )
            if validation.reasonCodes.count > 1 {
                extraReasonCodes.append(contentsOf: validation.reasonCodes.dropFirst())
            }
            let details = validation.isInjectable
                ? "Source validation passed for hot reload."
                : validation.details.joined(separator: " ")
            checks.append(CheckResult(
                id: "source_injectability",
                title: "Source Injectability",
                ok: validation.isInjectable,
                blocking: true,
                details: details,
                reasonCode: validation.reasonCodes.first
            ))
        }

        let hasBlockingFailure = checks.contains { !$0.ok && $0.blocking }
        let hasWarnings = checks.contains { !$0.ok && !$0.blocking }
        let status = hasBlockingFailure ? "FAIL" : (hasWarnings ? "WARN" : "PASS")
        let recommendedPath = hasBlockingFailure ? "preview_changes" : "hot_reload"
        var reasonCodes = checks.compactMap { check in
            check.ok ? nil : check.reasonCode
        }
        reasonCodes.append(contentsOf: extraReasonCodes)
        if !reasonCodes.isEmpty {
            var seen = Set<String>()
            reasonCodes = reasonCodes.filter { seen.insert($0).inserted }
        }

        let passedCount = checks.filter(\.ok).count
        let summary = "hot_reload_doctor: \(status) (\(passedCount)/\(checks.count) checks passed)"

        var payload: [String: Any] = [
            "status": status,
            "summary": summary,
            "recommended_path": recommendedPath,
            "reason_codes": reasonCodes,
            "checks": checks.map { $0.asJSON() },
            "context": [
                "app_name": appName,
                "project_root": projectRoot.map { $0 as Any } ?? NSNull(),
                "build_products_path": buildProbe.foundPath.map { $0 as Any } ?? NSNull()
            ]
        ]

        if !buildProbe.searchedPaths.isEmpty {
            payload["searched_paths"] = Array(buildProbe.searchedPaths.prefix(20))
        }

        return .text(Self.prettyJSONString(payload))
    }

    private static func prettyJSONString(_ json: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"FAIL\",\"summary\":\"hot_reload_doctor failed to serialize output\"}"
        }
        return text
    }

    private static func defaultBuildProductsProbe(appName: String, projectRoot: String?) -> BuildProductsProbe {
        let packageRoot = HotReloadBuildProductsLocator.packageRootFromFilePath(#filePath)
        let resolution = HotReloadBuildProductsLocator.resolve(
            appName: appName,
            projectRoot: projectRoot,
            packageRoot: packageRoot
        )

        return BuildProductsProbe(
            foundPath: resolution.foundPath,
            searchedPaths: resolution.searchedPaths,
            hasApusSwiftmodule: resolution.hasApusSwiftmodule
        )
    }

    private static func defaultInterposableProbe(projectRoot: String?) -> InterposableProbe {
        guard let projectRoot else {
            return InterposableProbe(
                detected: false,
                evidence: "Cannot inspect linker flags without project root."
            )
        }

        let fm = FileManager.default
        var filesToScan: [String] = [
            projectRoot + "/build-and-run.sh",
            projectRoot + "/project.yml"
        ]

        if let contents = try? fm.contentsOfDirectory(atPath: projectRoot) {
            for item in contents where item.hasSuffix(".xcodeproj") {
                filesToScan.append(projectRoot + "/" + item + "/project.pbxproj")
            }
        }

        for path in filesToScan {
            guard fm.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            if content.contains("-Xlinker -interposable") || content.contains("-interposable") {
                return InterposableProbe(
                    detected: true,
                    evidence: "Detected interposable linker hint in: \(path)"
                )
            }
        }

        return InterposableProbe(
            detected: false,
            evidence: "Could not detect -interposable in build-and-run.sh/project.yml/pbxproj."
        )
    }
}
#endif
