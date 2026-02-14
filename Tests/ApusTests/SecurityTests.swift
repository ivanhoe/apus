import XCTest
@testable import Apus

final class SecurityTests: XCTestCase {

    var middleware: SecurityMiddleware!

    override func setUp() {
        super.setUp()
        middleware = SecurityMiddleware()
    }

    // MARK: - Origin Validation

    func testNoOriginHeaderIsAllowed() {
        XCTAssertTrue(middleware.validateOrigin(headers: [:]))
    }

    func testLocalhostOriginIsAllowed() {
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "http://localhost"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "http://localhost:3000"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "http://127.0.0.1"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "http://127.0.0.1:8080"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "https://localhost"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "https://127.0.0.1"]))
    }

    func testVSCodeOriginIsAllowed() {
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "vscode-webview://extension-id"]))
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "vscode-file://something"]))
    }

    func testNullOriginIsAllowed() {
        XCTAssertTrue(middleware.validateOrigin(headers: ["origin": "null"]))
    }

    func testExternalOriginIsBlocked() {
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "http://evil.com"]))
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "https://attacker.com"]))
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "http://192.168.1.100"]))
    }

    // MARK: - Path Sanitization

    func testValidRelativePath() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("Documents/file.txt", basePath: base)
        XCTAssertEqual(result, "/Users/test/sandbox/Documents/file.txt")
    }

    func testPathTraversalIsBlocked() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("../../../etc/passwd", basePath: base)
        XCTAssertNil(result)
    }

    func testDoublePathTraversalIsBlocked() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("Documents/../../secret", basePath: base)
        XCTAssertNil(result)
    }

    func testAbsolutePathOutsideSandboxIsBlocked() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("/etc/passwd", basePath: base)
        XCTAssertNil(result)
    }

    func testAbsolutePathInsideSandboxIsAllowed() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("/Users/test/sandbox/Documents/file.txt", basePath: base)
        XCTAssertEqual(result, "/Users/test/sandbox/Documents/file.txt")
    }

    func testEmptyPathResolvesToBase() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("", basePath: base)
        // Empty path appended to base should still be within base
        XCTAssertNotNil(result)
    }
}
