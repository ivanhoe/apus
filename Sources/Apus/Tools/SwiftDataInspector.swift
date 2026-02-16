import Foundation

#if canImport(SwiftData)
import SwiftData
#endif

/// MCP tool that inspects SwiftData models.
/// Lists the schema (model types, attributes, relationships) from the ModelContainer.
/// For fetching records, use inspect_core_data with the underlying CoreData context,
/// or register specific model instances with inspect_object.
@available(iOS 17, macOS 14, *)
final class SwiftDataInspector: MCPTool {
    var toolName: String { "inspect_swift_data" }
    var toolDescription: String {
        "Inspect SwiftData model schema from the ModelContainer. Lists all model types, their attributes, and relationships. For fetching specific records, register model instances with Apus.register() and use inspect_object."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "model": [
                    "type": "string",
                    "description": "Model type name to get details for. Omit to list all models."
                ]
            ] as [String: Any]
        ]
    }

    #if canImport(SwiftData)
    private let container: ModelContainer?

    init(container: Any) {
        self.container = container as? ModelContainer
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let container else {
            return .error("Invalid modelContainer: expected SwiftData ModelContainer.")
        }

        let targetModel = arguments["model"] as? String
        let schema = container.schema

        let entities = schema.entities

        if entities.isEmpty {
            return .text("No SwiftData models found in the container schema.")
        }

        if let targetModel = targetModel {
            guard let entity = entities.first(where: { $0.name == targetModel }) else {
                let available = entities.map(\.name).joined(separator: ", ")
                return .error("Model '\(targetModel)' not found. Available models: \(available)")
            }
            return .text(formatEntity(entity, detailed: true))
        }

        let formatted = entities.map { formatEntity($0, detailed: false) }.joined(separator: "\n\n")
        return .text("SwiftData Models (\(entities.count)):\n\n\(formatted)")
    }

    private func formatEntity(_ entity: Schema.Entity, detailed: Bool) -> String {
        var result = entity.name

        let properties = entity.properties
        let attributes = properties.compactMap { $0 as? Schema.Attribute }
        let relationships = properties.compactMap { $0 as? Schema.Relationship }

        if !attributes.isEmpty {
            let attrLines = attributes.map { attr in
                let optional = attr.isOptional ? "?" : ""
                return "    \(attr.name): \(attr.valueType)\(optional)"
            }.joined(separator: "\n")
            result += "\n  Attributes:\n\(attrLines)"
        }

        if !relationships.isEmpty {
            let relLines = relationships.map { rel in
                let optional = rel.isOptional ? "?" : ""
                return "    \(rel.name): \(rel.valueType)\(optional)"
            }.joined(separator: "\n")
            result += "\n  Relationships:\n\(relLines)"
        }

        if detailed {
            result += "\n\n  Note: SwiftData uses type-safe generics, so dynamic record fetching"
            result += "\n  is not supported. Register specific model instances with"
            result += "\n  Apus.shared.register(myModel, id: \"myId\") and use"
            result += "\n  the inspect_object tool to inspect them."
        }

        return result
    }

    #else
    // Fallback for platforms without SwiftData
    init(container: Any) {}

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        return .error("SwiftData is not available on this platform.")
    }
    #endif
}
