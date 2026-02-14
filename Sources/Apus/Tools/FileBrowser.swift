import Foundation

/// MCP tool that lists files in the app's sandbox directory.
final class FileBrowser: MCPTool {
    var toolName: String { "browse_files" }
    var toolDescription: String {
        "Browse files in the app's sandbox directory. Lists files with sizes and modification dates."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Relative path within the app sandbox (default: root). Examples: 'Documents/', 'Library/Caches/'"
                ],
                "recursive": [
                    "type": "boolean",
                    "description": "Whether to list files recursively (default: false)"
                ]
            ] as [String: Any]
        ]
    }

    private let sandboxRoot: String
    private let security: SecurityMiddleware
    private let dateFormatter: ISO8601DateFormatter
    private let byteFormatter: ByteCountFormatter

    init(security: SecurityMiddleware) {
        self.sandboxRoot = NSHomeDirectory()
        self.security = security
        self.dateFormatter = ISO8601DateFormatter()
        self.byteFormatter = ByteCountFormatter()
        self.byteFormatter.allowedUnits = [.useAll]
        self.byteFormatter.countStyle = .file
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        let relativePath = arguments["path"] as? String ?? ""
        let recursive = arguments["recursive"] as? Bool ?? false

        let fullPath: String
        if relativePath.isEmpty {
            fullPath = sandboxRoot
        } else {
            guard let safePath = security.sanitizePath(relativePath, basePath: sandboxRoot) else {
                return .error("Invalid path: path traversal detected")
            }
            fullPath = safePath
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else {
            return .error("Path does not exist or is not a directory: \(relativePath.isEmpty ? "/" : relativePath)")
        }

        var entries: [String] = []

        if recursive {
            if let enumerator = fm.enumerator(atPath: fullPath) {
                while let file = enumerator.nextObject() as? String {
                    entries.append(formatEntry(file, basePath: fullPath))
                }
            }
        } else {
            let contents = (try? fm.contentsOfDirectory(atPath: fullPath)) ?? []
            for file in contents.sorted() {
                entries.append(formatEntry(file, basePath: fullPath))
            }
        }

        let displayPath = relativePath.isEmpty ? "/" : relativePath
        if entries.isEmpty {
            return .text("Directory '\(displayPath)' is empty.\nSandbox root: \(sandboxRoot)")
        }

        return .text("Files in \(displayPath) (\(entries.count) items):\nSandbox root: \(sandboxRoot)\n\n\(entries.joined(separator: "\n"))")
    }

    private func formatEntry(_ file: String, basePath: String) -> String {
        let filePath = basePath + "/" + file
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        let size = attrs?[.size] as? UInt64 ?? 0
        let modified = attrs?[.modificationDate] as? Date
        let isDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let dateStr = modified.map { dateFormatter.string(from: $0) } ?? "unknown"
        let marker = isDirectory ? "[DIR] " : "      "
        let sizeStr = isDirectory ? "-" : byteFormatter.string(fromByteCount: Int64(size))
        return "\(marker)\(file)\t\(sizeStr)\t\(dateStr)"
    }
}

/// MCP tool that reads a file from the app's sandbox.
final class FileReader: MCPTool {
    var toolName: String { "read_file" }
    var toolDescription: String {
        "Read the contents of a file in the app's sandbox. Returns text content for text files, or base64 for binary files."
    }
    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Relative path within the app sandbox (e.g., 'Documents/config.json')"
                ],
                "max_size": [
                    "type": "integer",
                    "description": "Maximum file size to read in bytes (default: 1048576 = 1MB)"
                ]
            ] as [String: Any],
            "required": ["path"]
        ]
    }

    private let sandboxRoot: String
    private let security: SecurityMiddleware

    init(security: SecurityMiddleware) {
        self.sandboxRoot = NSHomeDirectory()
        self.security = security
    }

    func execute(arguments: [String: Any]) async throws -> MCPToolResult {
        guard let relativePath = arguments["path"] as? String else {
            return .error("Missing required parameter: 'path'")
        }

        let maxSize = arguments["max_size"] as? Int ?? 1_048_576 // 1MB default

        guard let fullPath = security.sanitizePath(relativePath, basePath: sandboxRoot) else {
            return .error("Invalid path: path traversal detected")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
            if isDir.boolValue {
                return .error("'\(relativePath)' is a directory. Use browse_files instead.")
            }
            return .error("File not found: \(relativePath)")
        }

        guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
              let size = attrs[.size] as? UInt64 else {
            return .error("Cannot read file attributes: \(relativePath)")
        }

        if size > maxSize {
            return .error("File too large (\(size) bytes). Increase max_size parameter (current: \(maxSize)).")
        }

        guard let data = fm.contents(atPath: fullPath) else {
            return .error("Cannot read file: \(relativePath)")
        }

        // Try to read as text first
        if let text = String(data: data, encoding: .utf8) {
            return .text("File: \(relativePath) (\(size) bytes)\n\n\(text)")
        }

        // Binary file: return base64
        let base64 = data.base64EncodedString()
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return .text("File: \(relativePath) (\(size) bytes, binary)\nExtension: \(ext)\nBase64:\n\(base64)")
    }
}
