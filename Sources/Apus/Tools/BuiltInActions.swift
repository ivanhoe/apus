import Foundation

/// Registers built-in actions that work in any app without developer code.
/// These use system APIs (URLCache, UserDefaults, FileManager, etc.)
/// that are always available.
enum BuiltInActions {

    static func register(on runner: ActionRunner) {
        registerCacheActions(on: runner)
        registerUserDefaultsActions(on: runner)
        registerFileActions(on: runner)
        #if canImport(UIKit) && !os(watchOS)
        registerUIActions(on: runner)
        #endif
    }

    // MARK: - Cache

    private static func registerCacheActions(on runner: ActionRunner) {
        runner.register(
            name: "clear_url_cache",
            description: "Clear the shared URL cache (images, API responses, etc.)"
        ) {
            let before = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
            URLCache.shared.removeAllCachedResponses()
            return "URL cache cleared (\(formatBytes(before)) freed)"
        }

        runner.register(
            name: "clear_cookies",
            description: "Delete all HTTP cookies"
        ) {
            let storage = HTTPCookieStorage.shared
            let count = storage.cookies?.count ?? 0
            storage.cookies?.forEach { storage.deleteCookie($0) }
            return "Deleted \(count) cookies"
        }

        runner.register(
            name: "clear_tmp",
            description: "Delete all files in the app's tmp directory"
        ) {
            let tmp = FileManager.default.temporaryDirectory
            let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            var deleted = 0
            for file in files {
                try? FileManager.default.removeItem(at: file)
                deleted += 1
            }
            return "Deleted \(deleted) files from tmp/"
        }
    }

    // MARK: - UserDefaults

    private static func registerUserDefaultsActions(on runner: ActionRunner) {
        runner.register(
            name: "set_user_default",
            description: "Set a UserDefaults value. Pass arguments: {\"key\": \"app.theme\", \"value\": \"dark\"}"
        ) { args in
            guard let key = args["key"] as? String else {
                return "Error: 'key' argument is required"
            }
            guard let value = args["value"] else {
                return "Error: 'value' argument is required"
            }
            UserDefaults.standard.set(value, forKey: key)
            return "Set UserDefaults[\"\(key)\"] = \(value)"
        }

        runner.register(
            name: "delete_user_default",
            description: "Remove a key from UserDefaults. Pass arguments: {\"key\": \"app.theme\"}"
        ) { args in
            guard let key = args["key"] as? String else {
                return "Error: 'key' argument is required"
            }
            let existed = UserDefaults.standard.object(forKey: key) != nil
            UserDefaults.standard.removeObject(forKey: key)
            return existed ? "Removed UserDefaults[\"\(key)\"]" : "Key \"\(key)\" was not set"
        }

        runner.register(
            name: "clear_all_user_defaults",
            description: "Remove ALL app-specific UserDefaults keys (preserves Apple system keys)"
        ) {
            let defaults = UserDefaults.standard
            let allKeys = defaults.dictionaryRepresentation().keys
            let appKeys = allKeys.filter { key in
                !key.hasPrefix("Apple") && !key.hasPrefix("NS") && !key.hasPrefix("com.apple")
            }
            appKeys.forEach { defaults.removeObject(forKey: $0) }
            return "Cleared \(appKeys.count) UserDefaults keys"
        }
    }

    // MARK: - Files

    private static func registerFileActions(on runner: ActionRunner) {
        runner.register(
            name: "delete_file",
            description: "Delete a file from the app sandbox. Pass arguments: {\"path\": \"Documents/cache.json\"}"
        ) { args in
            guard let path = args["path"] as? String else {
                return "Error: 'path' argument is required"
            }
            let home = NSHomeDirectory()
            let fullPath = (home as NSString).appendingPathComponent(path)

            guard fullPath.hasPrefix(home) else {
                return "Error: path must be within the app sandbox"
            }
            guard FileManager.default.fileExists(atPath: fullPath) else {
                return "Error: file not found at '\(path)'"
            }

            try FileManager.default.removeItem(atPath: fullPath)
            return "Deleted '\(path)'"
        }

        runner.register(
            name: "write_file",
            description: "Write text content to a file in the app sandbox. Pass arguments: {\"path\": \"Documents/test.json\", \"content\": \"{}\"}"
        ) { args in
            guard let path = args["path"] as? String else {
                return "Error: 'path' argument is required"
            }
            guard let content = args["content"] as? String else {
                return "Error: 'content' argument is required"
            }
            let home = NSHomeDirectory()
            let fullPath = (home as NSString).appendingPathComponent(path)

            guard fullPath.hasPrefix(home) else {
                return "Error: path must be within the app sandbox"
            }

            let dir = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            try content.write(toFile: fullPath, atomically: true, encoding: .utf8)
            return "Wrote \(content.count) chars to '\(path)'"
        }
    }

    // MARK: - UI (iOS only)

    #if canImport(UIKit) && !os(watchOS)
    private static func registerUIActions(on runner: ActionRunner) {
        runner.register(
            name: "open_url",
            description: "Open a URL or deep link. Pass arguments: {\"url\": \"myapp://profile\"}"
        ) { args in
            guard let urlString = args["url"] as? String,
                  let url = URL(string: urlString) else {
                return "Error: valid 'url' argument is required"
            }
            await MainActor.run {
                UIApplication.shared.open(url)
            }
            return "Opened URL: \(urlString)"
        }

        runner.register(
            name: "set_appearance",
            description: "Switch app appearance. Pass arguments: {\"style\": \"dark\"} (dark/light/system)"
        ) { args in
            let style = args["style"] as? String ?? "system"
            let uiStyle: UIUserInterfaceStyle
            switch style.lowercased() {
            case "dark": uiStyle = .dark
            case "light": uiStyle = .light
            default: uiStyle = .unspecified
            }
            await MainActor.run {
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .forEach { $0.overrideUserInterfaceStyle = uiStyle }
            }
            return "Appearance set to \(style)"
        }
    }
    #endif

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / 1024 / 1024) MB"
    }
}
