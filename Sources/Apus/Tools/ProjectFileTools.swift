import Foundation

/// MCP tool that reads source files from the project directory (not the app sandbox).
final class ProjectFileReader: MCPTool {
    var toolName: String { "read_project_file" }
    var toolDescription: String {
        """
        Read a source file from the project directory. Use this to inspect Swift source files \
        before editing them. Paths are relative to the project root (where Package.swift or .xcodeproj lives). \
        Example: "ExampleApp/Sources/ContentView.swift" or "Sources/Apus/Tools/HotReloadTool.swift".
        """
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Relative path to the file from the project root"
                ],
                "max_lines": [
                    "type": "integer",
                    "description": "Maximum number of lines to return (default: 200). Use 0 for unlimited."
                ]
            ] as [String: Any],
            "required": ["file_path"]
        ]
    }

    private let projectRoot: String
    private let security: SecurityMiddleware

    init(projectRoot: String, security: SecurityMiddleware) {
        self.projectRoot = projectRoot
        self.security = security
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required parameter: 'file_path'")
        }

        guard let fullPath = security.sanitizePath(filePath, basePath: projectRoot) else {
            return .error("Invalid path: path traversal detected. Paths must be within the project root.")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
            return .error("File not found: \(filePath)")
        }
        if isDir.boolValue {
            return .error("'\(filePath)' is a directory. Provide a file path instead.")
        }

        guard let data = fm.contents(atPath: fullPath) else {
            return .error("Cannot read file: \(filePath)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .error("File is not a text file: \(filePath)")
        }

        let maxLines = arguments["max_lines"] as? Int ?? 200
        var lines = text.components(separatedBy: "\n")
        let totalLines = lines.count
        var truncated = false

        if maxLines > 0 && lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
        }

        // Add line numbers
        let numbered = lines.enumerated().map { i, line in
            String(format: "%4d  %@", i + 1, line)
        }.joined(separator: "\n")

        var header = "File: \(filePath) (\(totalLines) lines)"
        if truncated {
            header += " — showing first \(maxLines) lines"
        }

        return .text("\(header)\n\n\(numbered)")
    }
}

/// MCP tool that edits source files in the project directory using find-and-replace.
final class ProjectFileEditor: MCPTool {
    var toolName: String { "edit_project_file" }
    var toolDescription: String {
        """
        Edit a source file in the project by finding and replacing text. Use this to modify Swift source files \
        so changes persist across app restarts. Paths are relative to the project root. \
        After editing, use hot_reload with source_code to inject changes without recompiling.

        WORKFLOW: 1) read_project_file to see current code → 2) edit_project_file to modify it → 3) hot_reload with source_code
        """
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "Relative path to the file from the project root"
                ],
                "old_string": [
                    "type": "string",
                    "description": "The exact text to find in the file (must be unique)"
                ],
                "new_string": [
                    "type": "string",
                    "description": "The replacement text"
                ]
            ] as [String: Any],
            "required": ["file_path", "old_string", "new_string"]
        ]
    }

    private let projectRoot: String
    private let security: SecurityMiddleware

    init(projectRoot: String, security: SecurityMiddleware) {
        self.projectRoot = projectRoot
        self.security = security
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required parameter: 'file_path'")
        }
        guard let oldString = arguments["old_string"] as? String else {
            return .error("Missing required parameter: 'old_string'")
        }
        guard let newString = arguments["new_string"] as? String else {
            return .error("Missing required parameter: 'new_string'")
        }

        guard let fullPath = security.sanitizePath(filePath, basePath: projectRoot) else {
            return .error("Invalid path: path traversal detected. Paths must be within the project root.")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
            if isDir.boolValue {
                return .error("'\(filePath)' is a directory. Provide a file path instead.")
            }
            return .error("File not found: \(filePath)")
        }

        guard let data = fm.contents(atPath: fullPath),
              let content = String(data: data, encoding: .utf8) else {
            return .error("Cannot read file: \(filePath)")
        }

        // Count occurrences of old_string
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 0 {
            return .error("old_string not found in \(filePath). Make sure it matches exactly (including whitespace and indentation).")
        }

        if occurrences > 1 {
            return .error("old_string is ambiguous — found \(occurrences) occurrences in \(filePath). Provide more surrounding context to make the match unique.")
        }

        // Perform the replacement
        let newContent = content.replacingOccurrences(of: oldString, with: newString)

        do {
            try newContent.write(toFile: fullPath, atomically: true, encoding: .utf8)
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }

        // Show context around the edit
        let editedLines = newContent.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Find where the replacement was inserted
        if let range = newContent.range(of: newString) {
            let prefix = newContent[newContent.startIndex..<range.lowerBound]
            let lineNumber = prefix.components(separatedBy: "\n").count
            let startLine = max(1, lineNumber - 2)
            let endLine = min(editedLines.count, lineNumber + newLines.count + 1)

            let context = (startLine...endLine).map { i in
                String(format: "%4d  %@", i, editedLines[i - 1])
            }.joined(separator: "\n")

            return .text("Successfully edited \(filePath)\n\nContext around edit (lines \(startLine)-\(endLine)):\n\(context)")
        }

        return .text("Successfully edited \(filePath)")
    }
}
