import Foundation
import os
#if DEBUG
import Apus
#endif

/// App-wide loggers using Apple's standard Logger API.
/// Apus captures these automatically — zero extra code needed.
private let authLogger = Logger(subsystem: "com.apus.example", category: "Auth")
private let networkLogger = Logger(subsystem: "com.apus.example", category: "Network")
private let fileLogger = Logger(subsystem: "com.apus.example", category: "FileSystem")
private let prefsLogger = Logger(subsystem: "com.apus.example", category: "Preferences")
private let memoryLogger = Logger(subsystem: "com.apus.example", category: "Memory")

class AppState: ObservableObject {
    @Published var users: [User] = []
    @Published var selectedTab: Int = 0
    @Published var isLoggedIn: Bool = false
    @Published var currentUser: String = ""

    /// Memory buffers to demonstrate get_memory_stats
    private var memoryBuffers: [Data] = []

    init() {
        // Sample data
        users = [
            User(name: "Ivan Alvarez", email: "ivan@example.com", role: "Admin", loginCount: 42),
            User(name: "Ana Garcia", email: "ana@example.com", role: "Editor", loginCount: 15),
            User(name: "Carlos Lopez", email: "carlos@example.com", role: "Viewer", loginCount: 3),
            User(name: "Maria Torres", email: "maria@example.com", role: "Editor", loginCount: 28),
        ]

        // Seed UserDefaults
        UserDefaults.standard.set("ivan@example.com", forKey: "app.lastUser")
        UserDefaults.standard.set(true, forKey: "app.onboardingDone")
        UserDefaults.standard.set(7, forKey: "app.launchCount")
        UserDefaults.standard.set(Date(), forKey: "app.lastLaunch")
        UserDefaults.standard.set("dark", forKey: "app.theme")
    }

    // MARK: - Auth

    func login(as user: User) {
        currentUser = user.email
        isLoggedIn = true
        UserDefaults.standard.set(user.email, forKey: "app.lastUser")

        // Standard Apple Logger — Apus captures this automatically
        authLogger.info("User logged in: \(user.email) (role: \(user.role))")

        #if DEBUG
        Apus.shared.register(user, id: "currentUser")
        #endif
    }

    func logout() {
        authLogger.info("User logged out: \(self.currentUser)")

        #if DEBUG
        Apus.shared.unregister(id: "currentUser")
        #endif

        currentUser = ""
        isLoggedIn = false
    }

    // MARK: - Network

    func fetchAPI(endpoint: String) {
        networkLogger.debug("Fetching /\(endpoint)...")

        let url = URL(string: "https://jsonplaceholder.typicode.com/\(endpoint)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                networkLogger.error("Fetch /\(endpoint) failed: \(error.localizedDescription)")
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = data?.count ?? 0
            if statusCode >= 400 {
                networkLogger.error("Fetch /\(endpoint) returned \(statusCode)")
            } else {
                networkLogger.info("Fetch /\(endpoint) complete: \(statusCode) (\(size) bytes)")
            }
        }.resume()
    }

    // MARK: - Files

    func writeTestFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent("test-data.json")
        let data: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "users": users.map { ["name": $0.name, "email": $0.email, "role": $0.role] },
            "currentUser": currentUser,
            "isLoggedIn": isLoggedIn
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: fileURL)
            fileLogger.info("Wrote \(json.count) bytes to Documents/test-data.json")
        }
    }

    // MARK: - UserDefaults

    func updateDefaults() {
        let count = UserDefaults.standard.integer(forKey: "app.launchCount") + 1
        UserDefaults.standard.set(count, forKey: "app.launchCount")
        UserDefaults.standard.set(Date(), forKey: "app.lastAction")
        UserDefaults.standard.set(isLoggedIn ? currentUser : "none", forKey: "app.activeUser")
        prefsLogger.debug("UserDefaults updated (launchCount: \(count))")
    }

    // MARK: - Memory

    func allocateMemory() {
        let buffer = Data(repeating: 0xAB, count: 5 * 1024 * 1024) // 5MB
        memoryBuffers.append(buffer)
        let totalMB = memoryBuffers.count * 5
        memoryLogger.info("Allocated 5MB buffer (total retained: \(totalMB)MB, \(self.memoryBuffers.count) buffers)")
    }

    // MARK: - Demo: print() capture

    func triggerPrintLogs() {
        print("Debug: user tapped the print demo button")
        print("Session ID: \(UUID().uuidString)")
        NSLog("NSLog example: app state checked at %@", Date() as NSDate)
    }
}

struct User: Identifiable {
    let id = UUID()
    let name: String
    let email: String
    let role: String
    let loginCount: Int
}
