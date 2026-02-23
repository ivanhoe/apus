import XCTest
import CoreData
@testable import Apus

// MARK: - In-Memory CoreData Helpers

private func makeContext(
    entityName: String = "Person",
    attributes: [(name: String, type: NSAttributeType)] = [
        ("name", .stringAttributeType),
        ("age",  .integer32AttributeType)
    ]
) -> NSManagedObjectContext {
    let model  = NSManagedObjectModel()
    let entity = NSEntityDescription()
    entity.name = entityName
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
    entity.properties = attributes.map { pair in
        let attr = NSAttributeDescription()
        attr.name          = pair.name
        attr.attributeType = pair.type
        attr.isOptional    = true
        return attr
    }
    model.entities = [entity]

    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(
        ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)

    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
}

private func makeEmptyContext() -> NSManagedObjectContext {
    let model       = NSManagedObjectModel()
    let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try! coordinator.addPersistentStore(
        ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
    let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    context.persistentStoreCoordinator = coordinator
    return context
}

@discardableResult
private func insertObject(
    into context: NSManagedObjectContext,
    entityName: String,
    values: [String: Any]
) -> NSManagedObject {
    let desc = context.persistentStoreCoordinator!
        .managedObjectModel.entitiesByName[entityName]!
    let obj = NSManagedObject(entity: desc, insertInto: context)
    for (key, value) in values { obj.setValue(value, forKey: key) }
    try! context.save()
    return obj
}

// MARK: - CoreDataInspector Tests

@MainActor
final class CoreDataInspectorTests: XCTestCase {

    // MARK: Tool Metadata

    func testCoreDataInspector_toolName_isInspectCoreData() {
        let tool = CoreDataInspector(context: makeContext())
        XCTAssertEqual(tool.toolName, "inspect_core_data")
    }

    func testCoreDataInspector_toolDescription_isNotEmpty() {
        let tool = CoreDataInspector(context: makeContext())
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testCoreDataInspector_inputSchema_hasExpectedProperties() {
        let tool = CoreDataInspector(context: makeContext())
        XCTAssertEqual(tool.inputSchema["type"] as? String, "object")
        guard let properties = tool.inputSchema["properties"] as? [String: Any] else {
            XCTFail("Expected properties dictionary in input schema")
            return
        }
        XCTAssertNotNil(properties["entity"],    "'entity' parameter should be in schema")
        XCTAssertNotNil(properties["predicate"], "'predicate' parameter should be in schema")
        XCTAssertNotNil(properties["sort"],      "'sort' parameter should be in schema")
        XCTAssertNotNil(properties["limit"],     "'limit' parameter should be in schema")
    }

    // MARK: Entity Listing (no "entity" argument → listEntities path)

    func testCoreDataInspector_listEntities_withEmptyModel_returnsNoEntitiesMessage() async throws {
        let tool = CoreDataInspector(context: makeEmptyContext())
        let result = try await tool.execute(arguments: [:])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("No entities found"),
                      "Empty model should produce 'No entities found' message")
    }

    func testCoreDataInspector_listEntities_includesEntityName() async throws {
        let tool = CoreDataInspector(context: makeContext(entityName: "Widget"))
        let result = try await tool.execute(arguments: [:])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Widget"),        "Entity name should appear in listing")
        XCTAssertTrue(text.contains("CoreData Entities"), "Response should contain header")
    }

    func testCoreDataInspector_listEntities_includesStringAttributeType() async throws {
        let tool = CoreDataInspector(context: makeContext(
            entityName: "Item",
            attributes: [("title", .stringAttributeType)]
        ))
        let result = try await tool.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("title"),  "Attribute name 'title' should appear")
        XCTAssertTrue(text.contains("String"), "stringAttributeType should be labelled 'String'")
    }

    func testCoreDataInspector_listEntities_includesInteger32AttributeType() async throws {
        let tool = CoreDataInspector(context: makeContext(
            entityName: "Score",
            attributes: [("value", .integer32AttributeType)]
        ))
        let result = try await tool.execute(arguments: [:])
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Int32"),
                      "integer32AttributeType should be labelled 'Int32'")
    }

    // MARK: Record Fetching (with "entity" argument → fetchRecords path)

    func testCoreDataInspector_fetchRecords_withNoRecords_returnsNoRecordsMessage() async throws {
        let tool = CoreDataInspector(context: makeContext(entityName: "Person"))
        let result = try await tool.execute(arguments: ["entity": "Person"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("No records found"))
        XCTAssertTrue(text.contains("Person"))
    }

    func testCoreDataInspector_fetchRecords_withInsertedRecord_returnsRecord() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Alice", "age": 30])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Alice"))
        XCTAssertTrue(text.contains("1 records"))
    }

    func testCoreDataInspector_fetchRecords_withPredicate_filtersResults() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Alice", "age": 30])
        insertObject(into: context, entityName: "Person", values: ["name": "Bob",   "age": 25])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: [
            "entity":    "Person",
            "predicate": "name == 'Alice'"
        ])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Alice"))
        XCTAssertFalse(text.contains("Bob"), "Bob should be excluded by the predicate")
    }

    func testCoreDataInspector_fetchRecords_withPredicateAndNoMatch_includesPredicateInMessage() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Alice", "age": 30])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: [
            "entity":    "Person",
            "predicate": "name == 'Nonexistent'"
        ])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("No records found"),
                      "Should report no results when predicate matches nothing")
        XCTAssertTrue(text.contains("Nonexistent"),
                      "The predicate text should be echoed back in the message")
    }

    func testCoreDataInspector_fetchRecords_withSortAscending_returnsCorrectOrder() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Zara",    "age": 40])
        insertObject(into: context, entityName: "Person", values: ["name": "Aaron",   "age": 28])
        insertObject(into: context, entityName: "Person", values: ["name": "Miranda", "age": 35])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person", "sort": "name ASC"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        let aaronPos   = text.range(of: "Aaron")!.lowerBound
        let mirandaPos = text.range(of: "Miranda")!.lowerBound
        let zaraPos    = text.range(of: "Zara")!.lowerBound
        XCTAssertLessThan(aaronPos,   mirandaPos, "Aaron < Miranda in ASC sort")
        XCTAssertLessThan(mirandaPos, zaraPos,    "Miranda < Zara in ASC sort")
    }

    func testCoreDataInspector_fetchRecords_withSortDescending_returnsReverseOrder() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Aaron", "age": 28])
        insertObject(into: context, entityName: "Person", values: ["name": "Zara",  "age": 40])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person", "sort": "name DESC"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        let aaronPos = text.range(of: "Aaron")!.lowerBound
        let zaraPos  = text.range(of: "Zara")!.lowerBound
        XCTAssertGreaterThan(aaronPos, zaraPos, "Zara should precede Aaron in DESC sort")
    }

    func testCoreDataInspector_fetchRecords_withSortNoDirection_defaultsToAscending() async throws {
        // When no direction suffix is provided, the implementation defaults to ascending.
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Zara",  "age": 40])
        insertObject(into: context, entityName: "Person", values: ["name": "Aaron", "age": 28])
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person", "sort": "name"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        let aaronPos = text.range(of: "Aaron")!.lowerBound
        let zaraPos  = text.range(of: "Zara")!.lowerBound
        XCTAssertLessThan(aaronPos, zaraPos,
                          "Sort with no direction suffix should default to ascending")
    }

    func testCoreDataInspector_fetchRecords_withLimit_respectsLimit() async throws {
        let context = makeContext(entityName: "Person")
        for i in 1...10 {
            insertObject(into: context, entityName: "Person",
                         values: ["name": "P\(i)", "age": i])
        }
        let tool = CoreDataInspector(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person", "limit": 3])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("3 records"),
                      "A limit of 3 should yield exactly 3 records in the output")
    }

}

// MARK: - ExecuteFetchRequest Tests

@MainActor
final class ExecuteFetchRequestTests: XCTestCase {

    // MARK: Tool Metadata

    func testExecuteFetchRequest_toolName_isExecuteFetchRequest() {
        let tool = ExecuteFetchRequest(context: makeContext())
        XCTAssertEqual(tool.toolName, "execute_fetch_request")
    }

    func testExecuteFetchRequest_toolDescription_isNotEmpty() {
        let tool = ExecuteFetchRequest(context: makeContext())
        XCTAssertFalse(tool.toolDescription.isEmpty)
    }

    func testExecuteFetchRequest_inputSchema_hasRequiredEntityField() {
        let tool = ExecuteFetchRequest(context: makeContext())
        guard let required = tool.inputSchema["required"] as? [String] else {
            XCTFail("Expected 'required' array in input schema")
            return
        }
        XCTAssertTrue(required.contains("entity"),
                      "'entity' should be listed as a required field")
    }

    // MARK: Missing Argument

    func testExecuteFetchRequest_missingEntity_returnsError() async throws {
        let tool = ExecuteFetchRequest(context: makeContext())
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Missing required parameter"),
                      "Absent 'entity' argument should produce a clear error message")
    }

    // MARK: Empty Results

    func testExecuteFetchRequest_emptyEntity_returnsNoResults() async throws {
        let tool = ExecuteFetchRequest(context: makeContext(entityName: "Person"))
        let result = try await tool.execute(arguments: ["entity": "Person"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("No results"),
                      "An empty entity should report 'No results'")
    }

    // MARK: Records Present

    func testExecuteFetchRequest_withRecord_returnsFormattedTable() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Alice", "age": 30])
        let tool = ExecuteFetchRequest(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person"])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Alice"), "Result should contain the inserted value")
        XCTAssertTrue(text.contains("Person"), "Result should reference the entity name")
    }

    func testExecuteFetchRequest_withPredicate_filtersResults() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Alice", "age": 30])
        insertObject(into: context, entityName: "Person", values: ["name": "Bob",   "age": 25])
        let tool = ExecuteFetchRequest(context: context)
        let result = try await tool.execute(arguments: [
            "entity":    "Person",
            "predicate": "name == 'Bob'"
        ])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("Bob"))
        XCTAssertFalse(text.contains("Alice"), "Alice should be excluded by the predicate")
    }

    func testExecuteFetchRequest_withSortAscending_returnsOrderedTable() async throws {
        let context = makeContext(entityName: "Person")
        insertObject(into: context, entityName: "Person", values: ["name": "Zara",  "age": 35])
        insertObject(into: context, entityName: "Person", values: ["name": "Aaron", "age": 28])
        let tool = ExecuteFetchRequest(context: context)
        let result = try await tool.execute(arguments: [
            "entity": "Person",
            "sort":   "name ASC"
        ])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        let aaronPos = text.range(of: "Aaron")!.lowerBound
        let zaraPos  = text.range(of: "Zara")!.lowerBound
        XCTAssertLessThan(aaronPos, zaraPos, "Aaron should appear before Zara in ASC sort")
    }

    func testExecuteFetchRequest_withLimit_returnsLimitedRows() async throws {
        let context = makeContext(entityName: "Person")
        for i in 1...8 {
            insertObject(into: context, entityName: "Person",
                         values: ["name": "Person\(i)", "age": i])
        }
        let tool = ExecuteFetchRequest(context: context)
        let result = try await tool.execute(arguments: ["entity": "Person", "limit": 2])
        XCTAssertFalse(result.isError)
        guard case .text(let text) = result.content.first else {
            XCTFail("Expected text content"); return
        }
        XCTAssertTrue(text.contains("2 results"),
                      "Output should confirm only 2 results were returned")
    }

}
