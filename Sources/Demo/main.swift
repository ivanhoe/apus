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

// Start the MCP server
Apus.shared.start()

print("\n=== Try these commands in another terminal: ===\n")
print("# 1. Health check")
print("curl http://localhost:9847/\n")
print("# 2. MCP Initialize")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' | python3 -m json.tool\n")
print("# 3. List all tools")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}' | python3 -m json.tool\n")
print("# 4. Get logs")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_logs\",\"arguments\":{\"tail\":5}}}' | python3 -m json.tool\n")
print("# 5. Get logs (only errors)")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get_logs\",\"arguments\":{\"level\":\"error\"}}}' | python3 -m json.tool\n")
print("# 6. Get UserDefaults (our demo keys)")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_user_defaults\",\"arguments\":{\"prefix\":\"demo.\"}}}' | python3 -m json.tool\n")
print("# 7. Browse files")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"browse_files\",\"arguments\":{\"path\":\"\"}}}' | python3 -m json.tool\n")
print("# 8. Inspect registered object")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_object\",\"arguments\":{\"id\":\"currentUser\"}}}' | python3 -m json.tool\n")
print("# 9. List all registered objects")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"inspect_object\",\"arguments\":{}}}' | python3 -m json.tool\n")
print("# 10. Ping")
print("curl -s http://localhost:9847/mcp -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\",\"params\":{}}' | python3 -m json.tool\n")
print("Press Ctrl+C to stop the server.\n")

// Keep the process alive
dispatchMain()
