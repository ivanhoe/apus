import XCTest
@testable import Apus

final class ProjectFileReaderTests: XCTestCase {

    var reader: ProjectFileReader!
    let security = SecurityMiddleware()
    var projectRoot: String!

    override func setUp() {
        super.setUp()
        // Use the actual project root (where Package.swift lives)
        let thisFile = #filePath
        var url = URL(fileURLWithPath: thisFile)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.contains("Package.swift") {
                break
            }
        }
        projectRoot = url.path
        reader = ProjectFileReader(projectRoot: projectRoot, security: security)
    }

    func testToolMetadata() {
        XCTAssertEqual(reader.toolName, "read_project_file")
        XCTAssertFalse(reader.toolDescription.isEmpty)
    }

    func testSchemaHasFilePath() {
        let schema = reader.inputSchema
        let required = schema["required"] as? [String]
        XCTAssertEqual(required, ["file_path"])
    }

    func testReadsExistingFile() async throws {
        let result = try await reader.execute(arguments: ["file_path": "Package.swift"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Package.swift"))
        XCTAssertTrue(text.contains("Apus"))
    }

    func testBlocksPathTraversal() async throws {
        let result = try await reader.execute(arguments: ["file_path": "../../etc/passwd"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("path traversal"))
    }

    func testNonexistentFile() async throws {
        let result = try await reader.execute(arguments: ["file_path": "nonexistent_file_xyz.swift"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"))
    }

    func testReturnsLineNumbers() async throws {
        let result = try await reader.execute(arguments: ["file_path": "Package.swift"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        // Line numbers should appear in the output (e.g., "   1  ")
        XCTAssertTrue(text.contains("   1  "))
        XCTAssertTrue(text.contains("   2  "))
    }

    func testMissingFilePath() async throws {
        let result = try await reader.execute(arguments: [:])
        XCTAssertTrue(result.isError)
    }

    func testMaxLinesParameter() async throws {
        let result = try await reader.execute(arguments: ["file_path": "Package.swift", "max_lines": 3])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("showing first 3 lines"))
    }
}

final class ProjectFileEditorTests: XCTestCase {

    var editor: ProjectFileEditor!
    let security = SecurityMiddleware()
    var tempDir: String!

    override func setUp() {
        super.setUp()
        // Use a temp directory as "project root" for safe editing
        tempDir = NSTemporaryDirectory() + "apus_editor_tests_\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        editor = ProjectFileEditor(projectRoot: tempDir, security: security)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testToolMetadata() {
        XCTAssertEqual(editor.toolName, "edit_project_file")
        XCTAssertFalse(editor.toolDescription.isEmpty)
    }

    func testSchemaRequiresAllParams() {
        let schema = editor.inputSchema
        let required = schema["required"] as? [String]
        XCTAssertNotNil(required)
        XCTAssertTrue(required!.contains("file_path"))
        XCTAssertTrue(required!.contains("old_string"))
        XCTAssertTrue(required!.contains("new_string"))
    }

    func testRejectsPathTraversal() async throws {
        let result = try await editor.execute(arguments: [
            "file_path": "../../etc/passwd",
            "old_string": "root",
            "new_string": "hacked"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("path traversal"))
    }

    func testRejectsNonexistentFile() async throws {
        let result = try await editor.execute(arguments: [
            "file_path": "nonexistent.swift",
            "old_string": "foo",
            "new_string": "bar"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"))
    }

    func testRejectsStringNotFound() async throws {
        // Create a test file
        let filePath = tempDir + "/test.swift"
        try "let x = 42".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await editor.execute(arguments: [
            "file_path": "test.swift",
            "old_string": "let y = 99",
            "new_string": "let y = 100"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"))
    }

    func testSuccessfulEdit() async throws {
        // Create a test file
        let filePath = tempDir + "/test.swift"
        try "let color = Color.red\nlet size = 16".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await editor.execute(arguments: [
            "file_path": "test.swift",
            "old_string": "Color.red",
            "new_string": "Color.blue"
        ])
        XCTAssertFalse(result.isError)

        // Verify the file was actually modified
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(content.contains("Color.blue"))
        XCTAssertFalse(content.contains("Color.red"))

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Successfully edited"))
    }

    func testRejectsAmbiguousMatch() async throws {
        // Create a file with duplicated text
        let filePath = tempDir + "/test.swift"
        try "let a = 1\nlet b = 1\nlet c = 1".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await editor.execute(arguments: [
            "file_path": "test.swift",
            "old_string": "= 1",
            "new_string": "= 2"
        ])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("ambiguous"))
    }

    func testMissingRequiredParams() async throws {
        // Missing old_string
        let result1 = try await editor.execute(arguments: [
            "file_path": "test.swift",
            "new_string": "bar"
        ])
        XCTAssertTrue(result1.isError)

        // Missing new_string
        let result2 = try await editor.execute(arguments: [
            "file_path": "test.swift",
            "old_string": "foo"
        ])
        XCTAssertTrue(result2.isError)

        // Missing file_path
        let result3 = try await editor.execute(arguments: [
            "old_string": "foo",
            "new_string": "bar"
        ])
        XCTAssertTrue(result3.isError)
    }
}
