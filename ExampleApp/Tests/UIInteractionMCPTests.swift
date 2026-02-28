import XCTest
import UIKit
import Apus
import Foundation

@MainActor
final class UIInteractionMCPTests: XCTestCase {
    private var window: UIWindow!
    private var rootViewController: UIViewController!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let window = UIWindow(frame: UIScreen.main.bounds)
        let rootViewController = UIViewController()
        rootViewController.view.backgroundColor = .white
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()

        self.window = window
        self.rootViewController = rootViewController
    }

    override func tearDownWithError() throws {
        Apus.shared.stop()
        window?.isHidden = true
        window = nil
        rootViewController = nil
        try super.tearDownWithError()
    }

    func testTapOnUntappableViewReturnsError() async throws {
        let untappable = UIView(frame: CGRect(x: 20, y: 20, width: 120, height: 44))
        untappable.accessibilityIdentifier = "untappable_view"
        rootViewController.view.addSubview(untappable)

        let port = try await startServer()

        let response = try await callTool(
            on: port,
            name: "ui_interact",
            arguments: [
                "action": "tap",
                "identifier": "untappable_view"
            ]
        )

        XCTAssertTrue(toolIsError(response))
        XCTAssertTrue(toolText(response).contains("Failed to tap"))
    }

    func testSwipeOnTargetScrollViewUsesContentOffsetFallback() async throws {
        let scrollView = NonAccessibleScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 220))
        scrollView.contentSize = CGSize(width: 220, height: 1200)
        scrollView.accessibilityIdentifier = "manual_scroll_target"
        rootViewController.view.addSubview(scrollView)

        let port = try await startServer()

        let response = try await callTool(
            on: port,
            name: "ui_interact",
            arguments: [
                "action": "swipe",
                "direction": "down",
                "identifier": "manual_scroll_target"
            ]
        )

        XCTAssertFalse(toolIsError(response))
        XCTAssertTrue(toolText(response).contains("contentOffset"))
    }

    private func randomPort() -> UInt16 {
        UInt16(Int.random(in: 19000...23000))
    }

    private func startServer() async throws -> UInt16 {
        let maxAttempts = 8

        for _ in 0..<maxAttempts {
            let port = randomPort()
            Apus.shared.stop()
            Apus.shared.start(port: port, captureSystemLogs: false)

            if await waitForServer(on: port, timeout: 2.0) {
                return port
            }
            Apus.shared.stop()
        }

        throw NSError(
            domain: "UIInteractionMCPTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apus server did not become ready in time."]
        )
    }

    private func waitForServer(on port: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let probeJSON: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "probe",
            "method": "tools/list",
            "params": [:]
        ]

        while Date() < deadline {
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                request.httpMethod = "POST"
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: probeJSON)

                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, (200...499).contains(httpResponse.statusCode) {
                    return true
                }
            } catch {
                // keep polling until timeout
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return false
    }

    private func callTool(on port: UInt16, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let requestJSON: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ]

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestJSON)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func toolIsError(_ response: [String: Any]) -> Bool {
        let result = response["result"] as? [String: Any]
        return result?["isError"] as? Bool ?? false
    }

    private func toolText(_ response: [String: Any]) -> String {
        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

private final class NonAccessibleScrollView: UIScrollView {
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        false
    }
}
