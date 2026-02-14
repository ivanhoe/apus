import Foundation
import Apus

// ============================================
// Apus Demo
// ============================================
// This starts the MCP server on localhost:9847
// and registers some sample objects for testing.

print("=== Apus Demo ===\n")

// Register some sample objects before starting
class SampleUser {
    var name: String
    var email: String
    var loginCount: Int
    var isPremium: Bool

    init(name: String, email: String, loginCount: Int, isPremium: Bool) {
        self.name = name
        self.email = email
        self.loginCount = loginCount
        self.isPremium = isPremium
    }
}

struct AppConfig {
    let apiBaseURL: String
    let environment: String
    let debugMode: Bool
    let maxRetries: Int
}

let user = SampleUser(name: "Ivan", email: "ivan@example.com", loginCount: 42, isPremium: true)
let config = AppConfig(apiBaseURL: "https://api.example.com", environment: "development", debugMode: true, maxRetries: 3)

// Register objects for inspection
Apus.shared.register(user, id: "currentUser")
Apus.shared.register(config, id: "appConfig")

// Add some sample logs
Apus.shared.log("App launched successfully", level: "info", source: "AppDelegate")
Apus.shared.log("User session restored: ivan@example.com", level: "info", source: "AuthService")
Apus.shared.log("API base URL: https://api.example.com", level: "debug", source: "NetworkManager")
Apus.shared.log("Failed to refresh token: 401 Unauthorized", level: "error", source: "AuthService")
Apus.shared.log("Retrying request (attempt 2/3)", level: "warning", source: "NetworkManager")
Apus.shared.log("Cache cleared: 15 entries removed", level: "info", source: "CacheManager")
Apus.shared.log("Database migration completed v2 -> v3", level: "info", source: "CoreData")
Apus.shared.log("Push notification permission: denied", level: "warning", source: "NotificationService")

// Set some UserDefaults for testing
UserDefaults.standard.set("ivan@example.com", forKey: "demo.lastLoggedInUser")
UserDefaults.standard.set(true, forKey: "demo.onboardingComplete")
UserDefaults.standard.set(3, forKey: "demo.launchCount")
UserDefaults.standard.set(Date(), forKey: "demo.lastLaunchDate")

// Register actions
Apus.shared
    .action("clear_cache", description: "Clear all demo caches and UserDefaults") {
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("demo.") }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        return "Cleared \(keys.count) keys"
    }
    .action("add_user", description: "Add a new sample user to the registered objects") {
        let newUser = SampleUser(name: "New User", email: "new@example.com", loginCount: 0, isPremium: false)
        Apus.shared.register(newUser, id: "newUser")
        return "Added newUser — inspect with inspect_object"
    }
    .action("simulate_error", description: "Generate error logs to test error handling") {
        Apus.shared.log("FATAL: Unhandled exception in main thread", level: "error", source: "Runtime")
        Apus.shared.log("Stack: AppDelegate.init() -> ConfigManager.load() -> JSONDecoder.decode()", level: "error", source: "Runtime")
        return "Error logs generated"
    }

// Start the MCP server
Apus.shared.start()

print("\nPress Ctrl+C to stop the server.\n")

// Keep the process alive
dispatchMain()
