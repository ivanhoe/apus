import XCTest
@testable import Apus

final class NetworkInterceptorTests: XCTestCase {

    var interceptor: NetworkInterceptor!

    override func setUp() {
        super.setUp()
        interceptor = NetworkInterceptor(bufferSize: 64)
    }

    func testToolMetadata() {
        XCTAssertEqual(interceptor.toolName, "get_network_history")
        XCTAssertFalse(interceptor.toolDescription.isEmpty)
    }

    func testEmptyHistory() async throws {
        let result = try await interceptor.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("No network requests recorded"))
    }

    func testRecordAndRetrieve() async throws {
        let url = URL(string: "https://api.example.com/users")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)

        let record = NetworkRecord(
            id: UUID(),
            timestamp: Date(),
            request: request,
            response: response,
            responseBody: "{\"ok\":true}".data(using: .utf8),
            error: nil,
            duration: 0.123
        )
        interceptor.record(record)

        let result = try await interceptor.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("api.example.com/users"))
        XCTAssertTrue(text.contains("200"))
        XCTAssertTrue(text.contains("123"))
        XCTAssertTrue(text.contains("{\"ok\":true}"))
    }

    func testFilterByURL() async throws {
        recordSample(url: "https://api.example.com/users", method: "GET")
        recordSample(url: "https://api.example.com/posts", method: "GET")
        recordSample(url: "https://other.com/data", method: "GET")

        let result = try await interceptor.execute(arguments: ["filter_url": "example.com"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("2 of 3"))
        XCTAssertTrue(text.contains("users"))
        XCTAssertTrue(text.contains("posts"))
        XCTAssertFalse(text.contains("other.com"))
    }

    func testFilterByMethod() async throws {
        recordSample(url: "https://api.example.com/users", method: "GET")
        recordSample(url: "https://api.example.com/users", method: "POST")
        recordSample(url: "https://api.example.com/users", method: "GET")

        let result = try await interceptor.execute(arguments: ["filter_method": "POST"])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("1 of 3"))
        XCTAssertTrue(text.contains("POST"))
    }

    func testTailParameter() async throws {
        for i in 1...10 {
            recordSample(url: "https://api.example.com/item/\(i)", method: "GET")
        }

        let result = try await interceptor.execute(arguments: ["tail": 3])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("3 of 10"))
    }

    func testRecordWithError() async throws {
        let url = URL(string: "https://api.example.com/fail")!
        let request = URLRequest(url: url)
        let error = URLError(.timedOut)

        let record = NetworkRecord(
            id: UUID(),
            timestamp: Date(),
            request: request,
            response: nil,
            responseBody: nil,
            error: error,
            duration: 30.0
        )
        interceptor.record(record)

        let result = try await interceptor.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("no response"))
        XCTAssertTrue(text.contains("Error"))
    }

    // MARK: - Watermark (since) tests

    func testSinceReturnsOnlyNewRequests() async throws {
        recordSample(url: "https://api.example.com/old", method: "GET")

        let result1 = try await interceptor.execute(arguments: [:])
        let watermark = extractWatermark(from: textContent(result1))
        XCTAssertNotNil(watermark)

        recordSample(url: "https://api.example.com/new1", method: "POST")
        recordSample(url: "https://api.example.com/new2", method: "GET")

        let result2 = try await interceptor.execute(arguments: ["since": watermark!])
        let text = textContent(result2)
        XCTAssertTrue(text.contains("new1"))
        XCTAssertTrue(text.contains("new2"))
        XCTAssertFalse(text.contains("/old"))
        XCTAssertTrue(text.contains("watermark:"))
    }

    func testSinceNoNewRequests() async throws {
        recordSample(url: "https://api.example.com/test", method: "GET")

        let result1 = try await interceptor.execute(arguments: [:])
        let watermark = extractWatermark(from: textContent(result1))

        let result2 = try await interceptor.execute(arguments: ["since": watermark!])
        let text = textContent(result2)
        XCTAssertTrue(text.contains("No new network requests"))
        XCTAssertTrue(text.contains("watermark:"))
    }

    func testWithoutSinceStillWorks() async throws {
        recordSample(url: "https://api.example.com/users", method: "GET")

        let result = try await interceptor.execute(arguments: ["tail": 10])
        let text = textContent(result)
        XCTAssertTrue(text.contains("users"))
        XCTAssertTrue(text.contains("watermark:"))
    }

    func testSchemaIncludesSinceParameter() {
        let properties = interceptor.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["since"], "Schema should include 'since' parameter")

        let sinceSchema = properties?["since"] as? [String: Any]
        XCTAssertEqual(sinceSchema?["type"] as? String, "integer")
    }

    // MARK: - Helpers

    private func recordSample(url: String, method: String) {
        let urlObj = URL(string: url)!
        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        let response = HTTPURLResponse(url: urlObj, statusCode: 200, httpVersion: nil, headerFields: nil)

        interceptor.record(NetworkRecord(
            id: UUID(),
            timestamp: Date(),
            request: request,
            response: response,
            responseBody: nil,
            error: nil,
            duration: 0.05
        ))
    }

    private func textContent(_ result: MCPToolResult) -> String {
        if case .text(let text) = result.content.first { return text }
        return ""
    }

    private func extractWatermark(from text: String) -> Int? {
        guard let range = text.range(of: "watermark: \\d+", options: .regularExpression) else { return nil }
        let match = String(text[range])
        return Int(match.replacingOccurrences(of: "watermark: ", with: ""))
    }
}
