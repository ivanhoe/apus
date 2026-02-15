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
}
