import XCTest
@testable import Apus

final class NetworkRequestDetailTests: XCTestCase {

    var interceptor: NetworkInterceptor!
    var detailTool: NetworkRequestDetail!

    override func setUp() {
        super.setUp()
        interceptor = NetworkInterceptor(bufferSize: 64)
        detailTool = NetworkRequestDetail(interceptor: interceptor)
    }

    // MARK: - Tool metadata

    func testToolMetadata() {
        XCTAssertEqual(detailTool.toolName, "get_network_request_detail")
        XCTAssertFalse(detailTool.toolDescription.isEmpty)
    }

    func testSchemaRequiresRequestId() {
        let required = detailTool.inputSchema["required"] as? [String]
        XCTAssertEqual(required, ["request_id"])

        let properties = detailTool.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["request_id"])
        XCTAssertNotNil(properties?["max_body_size"])
    }

    // MARK: - Error cases

    func testMissingRequestId() async throws {
        let result = try await detailTool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(textContent(result).contains("Missing required parameter"))
    }

    func testInvalidUUID() async throws {
        let result = try await detailTool.execute(arguments: ["request_id": "not-a-uuid"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(textContent(result).contains("Invalid UUID"))
    }

    func testRequestNotFound() async throws {
        let result = try await detailTool.execute(arguments: ["request_id": UUID().uuidString])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(textContent(result).contains("not found"))
    }

    // MARK: - Successful retrieval

    func testSuccessfulDetailRetrieval() async throws {
        let knownId = UUID()
        let record = makeRecord(
            id: knownId,
            url: "https://api.example.com/users",
            method: "POST",
            requestHeaders: ["Content-Type": "application/json", "Authorization": "Bearer token123"],
            requestBody: "{\"name\":\"Ivan\"}".data(using: .utf8),
            statusCode: 201,
            responseHeaders: ["X-Request-Id": "abc-123"],
            responseBody: "{\"id\":1,\"name\":\"Ivan\"}".data(using: .utf8)
        )
        interceptor.record(record)

        let result = try await detailTool.execute(arguments: ["request_id": knownId.uuidString])
        XCTAssertFalse(result.isError)

        let text = textContent(result)
        // Method and URL
        XCTAssertTrue(text.contains("POST"))
        XCTAssertTrue(text.contains("api.example.com/users"))
        // Request headers (complete, not truncated)
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("Authorization: Bearer token123"))
        // Request body (complete)
        XCTAssertTrue(text.contains("{\"name\":\"Ivan\"}"))
        // Response status
        XCTAssertTrue(text.contains("201"))
        // Response headers
        XCTAssertTrue(text.contains("X-Request-Id"))
        XCTAssertTrue(text.contains("abc-123"))
        // Response body (complete)
        XCTAssertTrue(text.contains("{\"id\":1,\"name\":\"Ivan\"}"))
        // Timing
        XCTAssertTrue(text.contains("Duration:"))
        XCTAssertTrue(text.contains("Timestamp:"))
    }

    func testRecordWithError() async throws {
        let knownId = UUID()
        let url = URL(string: "https://api.example.com/fail")!
        let request = URLRequest(url: url)

        let record = NetworkRecord(
            id: knownId,
            timestamp: Date(),
            request: request,
            response: nil,
            responseBody: nil,
            error: URLError(.timedOut),
            duration: 30.0
        )
        interceptor.record(record)

        let result = try await detailTool.execute(arguments: ["request_id": knownId.uuidString])
        XCTAssertFalse(result.isError)

        let text = textContent(result)
        XCTAssertTrue(text.contains("no response"))
        XCTAssertTrue(text.contains("Error"))
    }

    // MARK: - Body truncation

    func testBodyTruncationWithMaxBodySize() async throws {
        let knownId = UUID()
        let largeBody = String(repeating: "x", count: 1000).data(using: .utf8)!
        let record = makeRecord(
            id: knownId,
            url: "https://api.example.com/data",
            responseBody: largeBody
        )
        interceptor.record(record)

        let result = try await detailTool.execute(arguments: [
            "request_id": knownId.uuidString,
            "max_body_size": 100
        ])
        let text = textContent(result)
        XCTAssertTrue(text.contains("truncated"))
        XCTAssertTrue(text.contains("1000 bytes total"))
        XCTAssertTrue(text.contains("showing 100"))
    }

    func testMaxBodySizeZeroMeansUnlimited() async throws {
        let knownId = UUID()
        let largeBody = String(repeating: "a", count: 100_000).data(using: .utf8)!
        let record = makeRecord(
            id: knownId,
            url: "https://api.example.com/data",
            responseBody: largeBody
        )
        interceptor.record(record)

        let result = try await detailTool.execute(arguments: [
            "request_id": knownId.uuidString,
            "max_body_size": 0
        ])
        let text = textContent(result)
        XCTAssertFalse(text.contains("truncated"))
        XCTAssertTrue(text.contains("100000 bytes"))
    }

    func testDefaultMaxBodySizeDoesNotTruncateSmallBodies() async throws {
        let knownId = UUID()
        let smallBody = String(repeating: "b", count: 500).data(using: .utf8)!
        let record = makeRecord(
            id: knownId,
            url: "https://api.example.com/data",
            responseBody: smallBody
        )
        interceptor.record(record)

        // Default max_body_size = 51200 (50KB), body is 500 bytes
        let result = try await detailTool.execute(arguments: ["request_id": knownId.uuidString])
        let text = textContent(result)
        XCTAssertFalse(text.contains("truncated"))
        XCTAssertTrue(text.contains("500 bytes"))
    }

    func testBinaryBodyReturnsBase64() async throws {
        let knownId = UUID()
        // Create data that's not valid UTF-8
        let binaryData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
        let record = makeRecord(
            id: knownId,
            url: "https://api.example.com/image",
            responseBody: binaryData
        )
        interceptor.record(record)

        let result = try await detailTool.execute(arguments: ["request_id": knownId.uuidString])
        let text = textContent(result)
        XCTAssertTrue(text.contains("encoding: base64"))
        XCTAssertTrue(text.contains("8 bytes"))
    }

    // MARK: - Helpers

    private func makeRecord(
        id: UUID = UUID(),
        url: String = "https://api.example.com/test",
        method: String = "GET",
        requestHeaders: [String: String]? = nil,
        requestBody: Data? = nil,
        statusCode: Int = 200,
        responseHeaders: [String: String]? = nil,
        responseBody: Data? = nil
    ) -> NetworkRecord {
        let urlObj = URL(string: url)!
        var request = URLRequest(url: urlObj)
        request.httpMethod = method
        request.allHTTPHeaderFields = requestHeaders
        request.httpBody = requestBody

        let response = HTTPURLResponse(
            url: urlObj,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: responseHeaders
        )

        return NetworkRecord(
            id: id,
            timestamp: Date(),
            request: request,
            response: response,
            responseBody: responseBody,
            error: nil,
            duration: 0.123
        )
    }

    private func textContent(_ result: MCPToolResult) -> String {
        if case .text(let text) = result.content.first { return text }
        return ""
    }
}
