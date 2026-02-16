import Foundation

struct SecurityMiddleware {

    private let allowedOriginPrefixes = [
        "http://localhost",
        "http://127.0.0.1",
        "https://localhost",
        "https://127.0.0.1",
        "vscode-webview://",
        "vscode-file://"
    ]

    /// Validates that the request comes from an allowed origin.
    /// Allows requests with no Origin header (non-browser clients like curl, MCP clients).
    /// Blocks requests from disallowed browser origins to prevent CSRF.
    func validateOrigin(headers: [String: String]) -> Bool {
        guard let origin = originValue(from: headers) else {
            // No Origin header means non-browser client — allow
            return true
        }

        // "null" origin is intentionally rejected to reduce browser attack surface.
        guard origin != "null" else { return false }
        return allowedOriginPrefixes.contains { origin.hasPrefix($0) }
    }

    /// Returns a CORS-safe origin to echo in responses, if present and allowed.
    func allowedOrigin(headers: [String: String]) -> String? {
        guard validateOrigin(headers: headers) else { return nil }
        return originValue(from: headers)
    }

    /// Sanitizes a file path to prevent path traversal attacks.
    /// Returns the resolved path if it's within the sandbox, nil otherwise.
    func sanitizePath(_ path: String, basePath: String) -> String? {
        let baseResolvedPath = resolvePathHandlingNonexistentTail(basePath)
        let baseURL = URL(fileURLWithPath: baseResolvedPath).standardizedFileURL
        let candidateURL: URL

        if path.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: path)
        } else {
            candidateURL = baseURL.appendingPathComponent(path)
        }

        let candidatePath = candidateURL.standardizedFileURL.path
        let resolvedPath = resolvePathHandlingNonexistentTail(candidatePath)

        // Ensure resolved path is exactly the base or a descendant directory/file.
        if resolvedPath == baseResolvedPath {
            return resolvedPath
        }

        let basePrefix = baseResolvedPath.hasSuffix("/") ? baseResolvedPath : baseResolvedPath + "/"
        guard resolvedPath.hasPrefix(basePrefix) else {
            return nil
        }

        return resolvedPath
    }

    private func originValue(from headers: [String: String]) -> String? {
        headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvePathHandlingNonexistentTail(_ path: String) -> String {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var tailComponents: [String] = []

        while !fm.fileExists(atPath: current.path) {
            guard current.path != "/" else { break }

            let component = current.lastPathComponent
            guard !component.isEmpty else { break }

            tailComponents.insert(component, at: 0)
            current.deleteLastPathComponent()
        }

        var resolved = current.resolvingSymlinksInPath().standardizedFileURL
        for component in tailComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }
}
