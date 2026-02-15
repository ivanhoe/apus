import XCTest
@testable import Apus

final class TokenMeasurementTests: XCTestCase {

    func testMeasureAppInfo() async throws {
        let tool = AppInfoInspector()
        let before = chars(try await tool.execute(arguments: ["section": "full"]))
        let after = chars(try await tool.execute(arguments: [:]))
        print("[MEASURE] get_app_info       BEFORE=\(before) AFTER=\(after) SAVED=\(before-after) (\((before-after)*100/max(before,1))%)")
    }

    func testMeasureLogs() async throws {
        let log = LogCapture(bufferSize: 1024)
        for i in 1...100 {
            log.log("Sample log message \(i) with realistic content about app state", level: i % 5 == 0 ? "error" : "info", source: "AppModule")
        }
        let before = chars(try await log.execute(arguments: ["tail": 100]))
        let after = chars(try await log.execute(arguments: ["tail": 50]))
        print("[MEASURE] get_logs           BEFORE=\(before) AFTER=\(after) SAVED=\(before-after) (\((before-after)*100/max(before,1))%)")
    }

    func testMeasureNetwork() async throws {
        let net = NetworkInterceptor(bufferSize: 256)
        for i in 1...50 {
            let url = URL(string: "https://api.example.com/v2/users/\(i)?include=profile&fields=name,email")!
            var req = URLRequest(url: url)
            req.httpMethod = i % 3 == 0 ? "POST" : "GET"
            req.allHTTPHeaderFields = [
                "Authorization": "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-Request-ID": UUID().uuidString
            ]
            let resp = HTTPURLResponse(url: url, statusCode: i % 7 == 0 ? 500 : 200, httpVersion: nil, headerFields: nil)
            let body = "{\"id\":\(i),\"name\":\"User \(i)\",\"email\":\"user\(i)@example.com\",\"status\":\"active\"}".data(using: .utf8)
            net.record(NetworkRecord(id: UUID(), timestamp: Date(), request: req, response: resp, responseBody: body, error: nil, duration: 0.1))
        }
        let before = chars(try await net.execute(arguments: ["tail": 50, "include_headers": true]))
        let after = chars(try await net.execute(arguments: [:]))
        print("[MEASURE] get_network        BEFORE=\(before) AFTER=\(after) SAVED=\(before-after) (\((before-after)*100/max(before,1))%)")
    }

    func testMeasureUserDefaults() async throws {
        let tool = UserDefaultsReader()
        let before = chars(try await tool.execute(arguments: ["include_system": true]))
        let after = chars(try await tool.execute(arguments: [:]))
        print("[MEASURE] get_user_defaults  BEFORE=\(before) AFTER=\(after) SAVED=\(before-after) (\((before-after)*100/max(before,1))%)")
    }

    private func chars(_ result: MCPToolResult) -> Int {
        if case .text(let text) = result.content.first { return text.count }
        return 0
    }

}
