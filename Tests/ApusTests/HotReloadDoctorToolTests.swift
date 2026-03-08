import XCTest
@testable import Apus

final class HotReloadDoctorToolTests: XCTestCase {

    func testToolMetadata() {
        let registry = ToolRegistry()
        let tool = HotReloadDoctorTool(toolRegistry: registry)

        XCTAssertEqual(tool.toolName, "hot_reload_doctor")
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testSchemaIsObjectWithNoRequiredParams() {
        let registry = ToolRegistry()
        let tool = HotReloadDoctorTool(toolRegistry: registry)

        let schema = tool.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertNotNil(schema["properties"] as? [String: Any])
    }

    func testSchemaIncludesSourceValidationFields() {
        let registry = ToolRegistry()
        let tool = HotReloadDoctorTool(toolRegistry: registry)
        let properties = tool.inputSchema["properties"] as? [String: Any]
        let sourceCode = properties?["source_code"] as? [String: Any]
        let originalPath = properties?["original_path"] as? [String: Any]

        XCTAssertEqual(sourceCode?["type"] as? String, "string")
        XCTAssertEqual(originalPath?["type"] as? String, "string")
    }

    func testExecuteReturnsPassWhenAllChecksPass() async throws {
        let registry = ToolRegistry()
        registry.register(MockHotReloadTool())

        let tool = HotReloadDoctorTool(
            toolRegistry: registry,
            projectRootProvider: { "/tmp/MyApp" },
            appNameProvider: { "MyApp" },
            isDebugBuild: true,
            isSimulator: true,
            buildProductsProbe: { _, _ in
                .init(
                    foundPath: "/tmp/MyApp/build/Build/Products/Debug-iphonesimulator",
                    searchedPaths: ["/tmp/MyApp/build/Build/Products/Debug-iphonesimulator"],
                    hasApusSwiftmodule: true
                )
            },
            interposableProbe: { _ in
                .init(detected: true, evidence: "Detected interposable linker hint in: /tmp/MyApp/project.yml")
            }
        )

        let result = try await tool.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        let json = try XCTUnwrap(parseResultJSON(result))
        XCTAssertEqual(json["status"] as? String, "PASS")
        XCTAssertEqual(json["recommended_path"] as? String, "hot_reload")
        XCTAssertEqual((json["reason_codes"] as? [String])?.count, 0)
    }

    func testExecuteReturnsFailWhenHotReloadToolMissing() async throws {
        let registry = ToolRegistry()

        let tool = HotReloadDoctorTool(
            toolRegistry: registry,
            projectRootProvider: { "/tmp/MyApp" },
            appNameProvider: { "MyApp" },
            isDebugBuild: true,
            isSimulator: true,
            buildProductsProbe: { _, _ in
                .init(
                    foundPath: "/tmp/MyApp/build/Build/Products/Debug-iphonesimulator",
                    searchedPaths: ["/tmp/MyApp/build/Build/Products/Debug-iphonesimulator"],
                    hasApusSwiftmodule: true
                )
            },
            interposableProbe: { _ in
                .init(detected: true, evidence: "Detected interposable linker hint in: /tmp/MyApp/project.yml")
            }
        )

        let result = try await tool.execute(arguments: [:])
        let json = try XCTUnwrap(parseResultJSON(result))

        XCTAssertEqual(json["status"] as? String, "FAIL")
        XCTAssertEqual(json["recommended_path"] as? String, "preview_changes")

        let reasonCodes = json["reason_codes"] as? [String] ?? []
        XCTAssertTrue(reasonCodes.contains("HR_HOT_RELOAD_TOOL_MISSING"))
    }

    func testExecuteReturnsWarnForNonBlockingIssues() async throws {
        let registry = ToolRegistry()
        registry.register(MockHotReloadTool())

        let tool = HotReloadDoctorTool(
            toolRegistry: registry,
            projectRootProvider: { "/tmp/MyApp" },
            appNameProvider: { "MyApp" },
            isDebugBuild: true,
            isSimulator: true,
            buildProductsProbe: { _, _ in
                .init(
                    foundPath: "/tmp/MyApp/build/Build/Products/Debug-iphonesimulator",
                    searchedPaths: ["/tmp/MyApp/build/Build/Products/Debug-iphonesimulator"],
                    hasApusSwiftmodule: false
                )
            },
            interposableProbe: { _ in
                .init(detected: false, evidence: "Could not detect -interposable in build config.")
            }
        )

        let result = try await tool.execute(arguments: [:])
        let json = try XCTUnwrap(parseResultJSON(result))

        XCTAssertEqual(json["status"] as? String, "WARN")
        XCTAssertEqual(json["recommended_path"] as? String, "hot_reload")

        let reasonCodes = json["reason_codes"] as? [String] ?? []
        XCTAssertTrue(reasonCodes.contains("HR_APUS_SWIFTMODULE_MISSING"))
        XCTAssertTrue(reasonCodes.contains("HR_INTERPOSABLE_NOT_DETECTED"))
    }

    func testExecuteReturnsFailWhenSourceIsNotInjectable() async throws {
        let registry = ToolRegistry()
        registry.register(MockHotReloadTool())

        let tool = HotReloadDoctorTool(
            toolRegistry: registry,
            projectRootProvider: { "/tmp/MyApp" },
            appNameProvider: { "MyApp" },
            isDebugBuild: true,
            isSimulator: true,
            buildProductsProbe: { _, _ in
                .init(
                    foundPath: "/tmp/MyApp/build/Build/Products/Debug-iphonesimulator",
                    searchedPaths: ["/tmp/MyApp/build/Build/Products/Debug-iphonesimulator"],
                    hasApusSwiftmodule: true
                )
            },
            interposableProbe: { _ in
                .init(detected: true, evidence: "Detected interposable linker hint in: /tmp/MyApp/project.yml")
            }
        )

        let result = try await tool.execute(arguments: [
            "source_code": """
            import Foundation
            final class SessionStore {}
            """,
            "original_path": "Sources/AppState.swift"
        ])
        let json = try XCTUnwrap(parseResultJSON(result))

        XCTAssertEqual(json["status"] as? String, "FAIL")
        XCTAssertEqual(json["recommended_path"] as? String, "preview_changes")
        let reasonCodes = json["reason_codes"] as? [String] ?? []
        XCTAssertTrue(reasonCodes.contains("HR_SOURCE_CONTAINS_REFERENCE_TYPES"))
    }

    func testExecuteFindsDotBuildDerivedDataProducts() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let products = root
            .appendingPathComponent(".build/DerivedData/Build/Products/Debug-iphonesimulator")
        let moduleDir = products.appendingPathComponent("Apus.swiftmodule")
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: moduleDir.appendingPathComponent("arm64-apple-ios-simulator.swiftmodule").path,
            contents: Data("module".utf8)
        )

        let registry = ToolRegistry()
        registry.register(MockHotReloadTool())

        let tool = HotReloadDoctorTool(
            toolRegistry: registry,
            projectRootProvider: { root.path },
            appNameProvider: { "ApusFresh" },
            isDebugBuild: true,
            isSimulator: true,
            interposableProbe: { _ in
                .init(detected: true, evidence: "Detected interposable linker hint in test config.")
            }
        )

        let result = try await tool.execute(arguments: [:])
        let json = try XCTUnwrap(parseResultJSON(result))
        let context = json["context"] as? [String: Any]

        XCTAssertEqual(context?["build_products_path"] as? String, products.path)
        XCTAssertEqual(json["status"] as? String, "PASS")
    }

    // MARK: - Helpers

    private func parseResultJSON(_ result: MCPToolResult) throws -> [String: Any]? {
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content in doctor result")
            return nil
        }

        let data = try XCTUnwrap(text.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    private func makeTempDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("hot-reload-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private final class MockHotReloadTool: MCPTool {
    let toolName = "hot_reload"
    let toolDescription = "Mock hot reload tool"
    let inputSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        .text("ok")
    }
}
