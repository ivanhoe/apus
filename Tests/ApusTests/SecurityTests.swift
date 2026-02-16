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

    func testNullOriginIsBlocked() {
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "null"]))
    }

    func testExternalOriginIsBlocked() {
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "http://evil.com"]))
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "https://attacker.com"]))
        XCTAssertFalse(middleware.validateOrigin(headers: ["origin": "http://192.168.1.100"]))
    }

    func testAllowedOriginEchoForLocalhost() {
        XCTAssertEqual(
            middleware.allowedOrigin(headers: ["origin": "http://localhost:3000"]),
            "http://localhost:3000"
        )
    }

    func testAllowedOriginNilForBlockedOrigin() {
        XCTAssertNil(middleware.allowedOrigin(headers: ["origin": "https://evil.com"]))
        XCTAssertNil(middleware.allowedOrigin(headers: ["origin": "null"]))
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

    func testSiblingPathWithSharedPrefixIsBlocked() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("/Users/test/sandbox2/secret.txt", basePath: base)
        XCTAssertNil(result)
    }

    func testSymlinkEscapeIsBlocked() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apus_security_\(UUID().uuidString)")
        let sandbox = root.appendingPathComponent("sandbox")
        let outside = root.appendingPathComponent("outside")
        let linkPath = sandbox.appendingPathComponent("link")

        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createSymbolicLink(atPath: linkPath.path, withDestinationPath: outside.path)

        let result = middleware.sanitizePath("link/secret.txt", basePath: sandbox.path)
        XCTAssertNil(result)
    }

    func testEmptyPathResolvesToBase() {
        let base = "/Users/test/sandbox"
        let result = middleware.sanitizePath("", basePath: base)
        // Empty path appended to base should still be within base
        XCTAssertNotNil(result)
    }
}
