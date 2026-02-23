import XCTest
@testable import Apus

final class ConfigurationTests: XCTestCase {

    func testDefaultValues() {
        let config = ApusConfiguration()

        XCTAssertEqual(config.port, 9847)
        XCTAssertEqual(config.bindAddress, "127.0.0.1")
        XCTAssertFalse(config.interceptNetwork)
        XCTAssertNil(config.enabledTools)
        XCTAssertTrue(config.disabledTools.isEmpty)
        XCTAssertFalse(config.disableSystemLogCapture)
    }

    func testCustomValues() {
        let config = ApusConfiguration(
            port: 8080,
            bindAddress: "0.0.0.0",
            interceptNetwork: true,
            enabledTools: ["get_logs", "get_memory_stats"],
            disabledTools: ["get_keychain_items"],
            disableSystemLogCapture: true
        )

        XCTAssertEqual(config.port, 8080)
        XCTAssertEqual(config.bindAddress, "0.0.0.0")
        XCTAssertTrue(config.interceptNetwork)
        XCTAssertEqual(config.enabledTools, ["get_logs", "get_memory_stats"])
        XCTAssertEqual(config.disabledTools, ["get_keychain_items"])
        XCTAssertTrue(config.disableSystemLogCapture)
    }

    func testDisableSystemLogCaptureDefaultIsFalse() {
        let config = ApusConfiguration()
        XCTAssertFalse(config.disableSystemLogCapture,
                       "System log capture should be enabled by default")
    }

    func testEnabledToolsAllowlistIsAppliedAndDisabledToolsOverride() async throws {
        Apus.shared.stop()

        let port: UInt16 = 19847
        Apus.shared.start(
            port: port,
            captureSystemLogs: false,
            configuration: ApusConfiguration(
                enabledTools: ["get_logs", "get_diagnostics"],
                disabledTools: ["get_diagnostics"]
            )
        )
        defer { Apus.shared.stop() }

        try await Task.sleep(nanoseconds: 300_000_000)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            XCTFail("Expected HTTP response")
            return
        }
        XCTAssertEqual(httpResponse.statusCode, 200)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            XCTFail("Invalid JSON-RPC response")
            return
        }

        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["get_logs"])
    }

    // MARK: - Edge Cases

    func testConfiguration_nilEnabledTools_isDifferentFromEmptySet() {
        // nil means "no allowlist — all tools are permitted".
        // An empty Set means "allowlist is active but contains zero entries".
        let withNil   = ApusConfiguration(enabledTools: nil)
        let withEmpty = ApusConfiguration(enabledTools: [])

        XCTAssertNil(withNil.enabledTools,
                     "nil enabledTools should remain nil (all tools allowed)")
        XCTAssertNotNil(withEmpty.enabledTools,
                        "Empty Set is still a non-nil allowlist")
        XCTAssertTrue(withEmpty.enabledTools!.isEmpty)
    }

    func testConfiguration_mutability_portCanBeUpdated() {
        // ApusConfiguration is a struct with var stored properties.
        var config = ApusConfiguration()
        config.port = 8888
        XCTAssertEqual(config.port, 8888)
    }

    func testConfiguration_disabledTools_setSemantics_removeDuplicates() {
        // The Swift Set<String> type automatically deduplicates. Passing the same
        // tool name twice should yield a set of count 1.
        let config = ApusConfiguration(disabledTools: ["tool_a", "tool_a", "tool_b"])
        XCTAssertEqual(config.disabledTools.count, 2)
        XCTAssertTrue(config.disabledTools.contains("tool_a"))
        XCTAssertTrue(config.disabledTools.contains("tool_b"))
    }

    func testConfiguration_structCopy_changesAreIndependent() {
        // ApusConfiguration is a value type; assigning it creates an independent copy.
        let original = ApusConfiguration()
        var copy = original
        copy.port = 1234

        XCTAssertEqual(original.port, 9847,
                       "Mutating the copy should not affect the original")
        XCTAssertEqual(copy.port, 1234)
    }

    func testConfiguration_enabledToolsOnly_doesNotRequireDisabledTools() {
        let config = ApusConfiguration(enabledTools: ["get_logs"])
        XCTAssertNotNil(config.enabledTools)
        XCTAssertEqual(config.enabledTools, ["get_logs"])
        XCTAssertTrue(config.disabledTools.isEmpty,
                      "disabledTools should default to empty when not specified")
    }

    func testConfiguration_disabledToolsOnly_doesNotAffectEnabledTools() {
        let config = ApusConfiguration(disabledTools: ["get_keychain_items"])
        XCTAssertNil(config.enabledTools,
                     "enabledTools should remain nil when only disabledTools is set")
        XCTAssertEqual(config.disabledTools, ["get_keychain_items"])
    }
}
