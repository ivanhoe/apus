import XCTest
@testable import Apus

final class FileBrowserTests: XCTestCase {

    var browser: FileBrowser!
    var fileReader: FileReader!
    let security = SecurityMiddleware()

    override func setUp() {
        super.setUp()
        browser = FileBrowser(security: security)
        fileReader = FileReader(security: security)
    }

    override func tearDown() {
        // Clean up test files
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("apus_test.txt"))
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("apus_test.bin"))
        super.tearDown()
    }

    // MARK: - FileBrowser

    func testBrowseToolMetadata() {
        XCTAssertEqual(browser.toolName, "browse_files")
        XCTAssertFalse(browser.toolDescription.isEmpty)
    }

    func testBrowseRootDirectory() async throws {
        let result = try await browser.execute(arguments: [:])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Sandbox root should always have some directories
        XCTAssertTrue(text.contains("Documents") || text.contains("Library") || text.contains("tmp"))
    }

    func testBrowseDocumentsDirectory() async throws {
        // Create a test file first
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try "test content".write(to: docs.appendingPathComponent("apus_test.txt"), atomically: true, encoding: .utf8)

        let result = try await browser.execute(arguments: ["path": "Documents/"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("apus_test.txt"))
    }

    func testBrowsePathTraversalBlocked() async throws {
        let result = try await browser.execute(arguments: ["path": "../../../etc/"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("path traversal"))
    }

    func testBrowseNonexistentDirectory() async throws {
        let result = try await browser.execute(arguments: ["path": "NonExistentDir123/"])
        XCTAssertTrue(result.isError)
    }

    // MARK: - FileReader

    func testReadToolMetadata() {
        XCTAssertEqual(fileReader.toolName, "read_file")
        XCTAssertFalse(fileReader.toolDescription.isEmpty)
    }

    func testReadTextFile() async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try "Hello from Apus tests!".write(to: docs.appendingPathComponent("apus_test.txt"), atomically: true, encoding: .utf8)

        let result = try await fileReader.execute(arguments: ["path": "Documents/apus_test.txt"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Hello from Apus tests!"))
    }

    func testReadBinaryFile() async throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let binaryData = Data([0x00, 0xFF, 0xAB, 0xCD])
        try binaryData.write(to: docs.appendingPathComponent("apus_test.bin"))

        let result = try await fileReader.execute(arguments: ["path": "Documents/apus_test.bin"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Base64"))
        XCTAssertTrue(text.contains("binary"))
    }

    func testReadMissingPath() async throws {
        let result = try await fileReader.execute(arguments: [:])
        XCTAssertTrue(result.isError)
    }

    func testReadNonexistentFile() async throws {
        let result = try await fileReader.execute(arguments: ["path": "Documents/nonexistent_file_12345.txt"])
        XCTAssertTrue(result.isError)
    }

    func testReadPathTraversalBlocked() async throws {
        let result = try await fileReader.execute(arguments: ["path": "../../../etc/passwd"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("path traversal"))
    }

    func testReadDirectoryReturnsError() async throws {
        let result = try await fileReader.execute(arguments: ["path": "Documents"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("directory"))
    }
}
