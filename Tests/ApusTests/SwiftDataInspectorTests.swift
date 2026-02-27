import XCTest
@testable import Apus

#if canImport(SwiftData)
import SwiftData

@available(iOS 17, macOS 14, *)
@Model
final class ApusTestItem {
    var name: String
    var score: Int

    init(name: String, score: Int) {
        self.name = name
        self.score = score
    }
}

@available(iOS 17, macOS 14, *)
@Model
final class ApusTestTag {
    var label: String

    init(label: String) {
        self.label = label
    }
}

@available(iOS 17, macOS 14, *)
final class SwiftDataInspectorTests: XCTestCase {

    // MARK: - Error handling

    func testInvalidContainerReturnsErrorInsteadOfCrashing() async throws {
        let tool = SwiftDataInspector(container: "not-a-container")
        let result = try await tool.execute(arguments: [:])

        XCTAssertTrue(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("Invalid modelContainer"))
    }

    // MARK: - Tool metadata

    func testToolMetadata_nameAndDescription_areSet() {
        let tool = SwiftDataInspector(container: "not-a-container")
        XCTAssertEqual(tool.toolName, "inspect_swift_data")
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testSchemaHasModelParameter() {
        let tool = SwiftDataInspector(container: "not-a-container")
        guard let properties = tool.inputSchema["properties"] as? [String: Any],
              let modelProp = properties["model"] as? [String: Any] else {
            XCTFail("Expected 'model' property in schema")
            return
        }
        XCTAssertEqual(modelProp["type"] as? String, "string")
    }

    func testSchemaType_isObject() {
        let tool = SwiftDataInspector(container: "not-a-container")
        XCTAssertEqual(tool.inputSchema["type"] as? String, "object")
    }

    // MARK: - Real ModelContainer tests

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ApusTestItem.self, ApusTestTag.self, configurations: config)
    }

    func testListAllModels_isNotAnError() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: [:])
        XCTAssertFalse(result.isError)
    }

    func testListAllModels_showsAllRegisteredEntityNames() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }

        XCTAssertTrue(text.contains("ApusTestItem"), "Should list ApusTestItem model")
        XCTAssertTrue(text.contains("ApusTestTag"), "Should list ApusTestTag model")
    }

    func testListAllModels_showsModelCount() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("2"), "Should indicate 2 models registered")
    }

    func testListAllModels_showsAttributeNames() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("name"), "Should show 'name' attribute of ApusTestItem")
        XCTAssertTrue(text.contains("score"), "Should show 'score' attribute of ApusTestItem")
    }

    func testSpecificModel_returnsDetailedInfo() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: ["model": "ApusTestItem"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("ApusTestItem"))
        // Detailed view includes a note about register-based inspection
        XCTAssertTrue(text.contains("inspect_object") || text.contains("register"),
                      "Detailed model view should mention the inspect_object workflow")
    }

    func testSpecificModel_unknownName_returnsError() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: ["model": "DoesNotExistModel"])
        XCTAssertTrue(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("not found"), "Error should indicate model was not found")
        // Should also list what IS available
        XCTAssertTrue(text.contains("ApusTestItem") || text.contains("Available"),
                      "Error should list available model names")
    }

    func testSpecificModel_secondModel_returnsDetails() async throws {
        let container = try makeContainer()
        let tool = SwiftDataInspector(container: container)

        let result = try await tool.execute(arguments: ["model": "ApusTestTag"])
        XCTAssertFalse(result.isError)

        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content")
            return
        }
        XCTAssertTrue(text.contains("ApusTestTag"))
        XCTAssertTrue(text.contains("label"))
    }
}
#endif
