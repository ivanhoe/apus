import Foundation
import CoreData

/// MCP tool that inspects CoreData entities and records.
/// Without an entity name, lists all entities and their schemas.
/// With an entity name, fetches records with optional filtering and sorting.
final class CoreDataInspector: MCPTool {
    var toolName: String { "inspect_core_data" }
    var toolDescription: String {
        "Inspect CoreData entities and records. Without 'entity', lists all entity schemas. With 'entity', fetches records with optional predicate filtering and sorting."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "entity": [
                    "type": "string",
                    "description": "Entity name to inspect. Omit to list all entities."
                ],
                "predicate": [
                    "type": "string",
                    "description": "NSPredicate format string for filtering (e.g., 'age > 18', 'name CONTAINS \"Ivan\"')"
                ],
                "sort": [
                    "type": "string",
                    "description": "Sort descriptor: 'key ASC' or 'key DESC' (default: no sorting)"
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of results (default: 50)"
                ]
            ] as [String: Any]
        ]
    }

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let entityName = arguments["entity"] as? String else {
            return await listEntities()
        }

        return await fetchRecords(
            entity: entityName,
            predicate: arguments["predicate"] as? String,
            sort: arguments["sort"] as? String,
            limit: arguments["limit"] as? Int ?? 50
        )
    }

    // MARK: - Private

    private func listEntities() async -> MCPToolResult {
        return await MainActor.run {
            guard let model = context.persistentStoreCoordinator?.managedObjectModel else {
                return MCPToolResult.error("No managed object model available")
            }

            if model.entities.isEmpty {
                return MCPToolResult.text("No entities found in the CoreData model.")
            }

            let entities = model.entities.compactMap { entity -> String? in
                guard let name = entity.name else { return nil }

                let attributes = entity.attributesByName.map { key, attr in
                    "    \(key): \(attributeTypeDescription(attr.attributeType))"
                }.sorted().joined(separator: "\n")

                let relationships = entity.relationshipsByName.map { key, rel in
                    let dest = rel.destinationEntity?.name ?? "Unknown"
                    let type = rel.isToMany ? "toMany" : "toOne"
                    return "    \(key) -> \(dest) (\(type))"
                }.sorted().joined(separator: "\n")

                var result = name
                if !attributes.isEmpty {
                    result += "\n  Attributes:\n\(attributes)"
                }
                if !relationships.isEmpty {
                    result += "\n  Relationships:\n\(relationships)"
                }
                return result
            }.joined(separator: "\n\n")

            return MCPToolResult.text("CoreData Entities (\(model.entities.count)):\n\n\(entities)")
        }
    }

    private func fetchRecords(entity: String, predicate: String?, sort: String?, limit: Int) async -> MCPToolResult {
        return await MainActor.run {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.fetchLimit = min(limit, 200) // Safety cap

            if let predicateStr = predicate {
                let trimmed = predicateStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return MCPToolResult.error("Empty predicate string")
                }
                // Note: deeply malformed predicates raise ObjC NSException which
                // cannot be caught from pure Swift. Acceptable for a debug tool.
                request.predicate = NSPredicate(format: trimmed)
            }

            if let sort = sort {
                let parts = sort.split(separator: " ")
                if let key = parts.first {
                    let ascending = parts.count > 1 ? parts[1].uppercased() == "ASC" : true
                    request.sortDescriptors = [NSSortDescriptor(key: String(key), ascending: ascending)]
                }
            }

            do {
                let results = try context.fetch(request)

                if results.isEmpty {
                    return MCPToolResult.text("No records found for entity '\(entity)'" +
                        (predicate != nil ? " with predicate '\(predicate!)'" : "") + ".")
                }

                let formatted = results.enumerated().map { index, obj in
                    let attrs = obj.entity.attributesByName.keys.sorted().map { key in
                        let value = obj.value(forKey: key)
                        return "  \(key): \(value.map { String(describing: $0) } ?? "nil")"
                    }.joined(separator: "\n")
                    return "[\(index)] \(entity)\n\(attrs)"
                }.joined(separator: "\n\n")

                return MCPToolResult.text("CoreData results for '\(entity)' (\(results.count) records):\n\n\(formatted)")
            } catch {
                return MCPToolResult.error("Fetch failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Convenience tool for executing explicit fetch requests with full control.
final class ExecuteFetchRequest: MCPTool {
    var toolName: String { "execute_fetch_request" }
    var toolDescription: String {
        "Execute a CoreData fetch request with full control over entity, predicate, sorting, and limit. Read-only."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "entity": [
                    "type": "string",
                    "description": "Entity name (required)"
                ],
                "predicate": [
                    "type": "string",
                    "description": "NSPredicate format string"
                ],
                "sort": [
                    "type": "string",
                    "description": "Sort: 'key ASC' or 'key DESC'"
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max results (default: 10)"
                ]
            ] as [String: Any],
            "required": ["entity"]
        ]
    }

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let entity = arguments["entity"] as? String else {
            return .error("Missing required parameter: 'entity'")
        }

        return await MainActor.run {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.fetchLimit = arguments["limit"] as? Int ?? 10

            if let predicateStr = arguments["predicate"] as? String {
                let trimmed = predicateStr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    return MCPToolResult.error("Empty predicate string")
                }
                // Note: deeply malformed predicates raise ObjC NSException which
                // cannot be caught from pure Swift. Acceptable for a debug tool.
                request.predicate = NSPredicate(format: trimmed)
            }

            if let sort = arguments["sort"] as? String {
                let parts = sort.split(separator: " ")
                if let key = parts.first {
                    let ascending = parts.count > 1 ? parts[1].uppercased() == "ASC" : true
                    request.sortDescriptors = [NSSortDescriptor(key: String(key), ascending: ascending)]
                }
            }

            do {
                let results = try context.fetch(request)

                if results.isEmpty {
                    return MCPToolResult.text("No results.")
                }

                // Format as table
                let allKeys = results.first?.entity.attributesByName.keys.sorted() ?? []
                let header = allKeys.joined(separator: " | ")
                let separator = String(repeating: "-", count: header.count)

                let rows = results.map { obj in
                    allKeys.map { key in
                        let val = obj.value(forKey: key)
                        return val.map { String(describing: $0) } ?? "nil"
                    }.joined(separator: " | ")
                }.joined(separator: "\n")

                return MCPToolResult.text("\(entity) (\(results.count) results):\n\n\(header)\n\(separator)\n\(rows)")
            } catch {
                return MCPToolResult.error("Fetch failed: \(error.localizedDescription)")
            }
        }
    }
}

private func attributeTypeDescription(_ type: NSAttributeType) -> String {
    switch type {
    case .undefinedAttributeType: return "Undefined"
    case .integer16AttributeType: return "Int16"
    case .integer32AttributeType: return "Int32"
    case .integer64AttributeType: return "Int64"
    case .decimalAttributeType: return "Decimal"
    case .doubleAttributeType: return "Double"
    case .floatAttributeType: return "Float"
    case .stringAttributeType: return "String"
    case .booleanAttributeType: return "Boolean"
    case .dateAttributeType: return "Date"
    case .binaryDataAttributeType: return "BinaryData"
    case .UUIDAttributeType: return "UUID"
    case .URIAttributeType: return "URI"
    case .transformableAttributeType: return "Transformable"
    case .objectIDAttributeType: return "ObjectID"
    case .compositeAttributeType: return "Composite"
    @unknown default: return "Unknown"
    }
}
