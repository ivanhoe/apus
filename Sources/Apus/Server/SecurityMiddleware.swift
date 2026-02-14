import Foundation

struct SecurityMiddleware {

    /// Validates that the request comes from an allowed origin.
    /// Allows requests with no Origin header (non-browser clients like curl, MCP clients).
    /// Blocks requests from disallowed browser origins to prevent CSRF.
    func validateOrigin(headers: [String: String]) -> Bool {
        guard let origin = headers["origin"] else {
            // No Origin header means non-browser client — allow
            return true
        }

        let allowedPrefixes = [
            "http://localhost",
            "http://127.0.0.1",
            "https://localhost",
            "https://127.0.0.1",
            "vscode-webview://",
            "vscode-file://"
        ]

        // Some clients send "null" as origin
        if origin == "null" {
            return true
        }

        return allowedPrefixes.contains { origin.hasPrefix($0) }
    }

    /// Sanitizes a file path to prevent path traversal attacks.
    /// Returns the resolved path if it's within the sandbox, nil otherwise.
    func sanitizePath(_ path: String, basePath: String) -> String? {
        // Resolve the path relative to basePath
        let baseURL = URL(fileURLWithPath: basePath).standardized
        let resolvedURL: URL

        if path.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: path).standardized
        } else {
            resolvedURL = baseURL.appendingPathComponent(path).standardized
        }

        let resolvedPath = resolvedURL.path

        // Ensure resolved path is within the sandbox
        guard resolvedPath.hasPrefix(baseURL.path) else {
            return nil
        }

        return resolvedPath
    }
}
