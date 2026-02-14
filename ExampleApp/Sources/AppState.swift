import Foundation
#if DEBUG
import Apus
#endif

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

        #if DEBUG
        Apus.shared.log("User logged in: \(user.email) (role: \(user.role))", level: "info", source: "Auth")
        Apus.shared.register(user, id: "currentUser")
        #endif
    }

    func logout() {
        #if DEBUG
        Apus.shared.log("User logged out: \(currentUser)", level: "info", source: "Auth")
        Apus.shared.unregister(id: "currentUser")
        #endif

        currentUser = ""
        isLoggedIn = false
    }

    // MARK: - Network

    func fetchAPI(endpoint: String) {
        #if DEBUG
        Apus.shared.log("Fetching /\(endpoint)...", level: "debug", source: "Network")
        #endif

        let url = URL(string: "https://jsonplaceholder.typicode.com/\(endpoint)")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                #if DEBUG
                Apus.shared.log("Fetch /\(endpoint) failed: \(error.localizedDescription)", level: "error", source: "Network")
                #endif
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = data?.count ?? 0
            #if DEBUG
            if statusCode >= 400 {
                Apus.shared.log("Fetch /\(endpoint) returned \(statusCode)", level: "error", source: "Network")
            } else {
                Apus.shared.log("Fetch /\(endpoint) complete: \(statusCode) (\(size) bytes)", level: "info", source: "Network")
            }
            #endif
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
            #if DEBUG
            Apus.shared.log("Wrote \(json.count) bytes to Documents/test-data.json", level: "info", source: "FileSystem")
            #endif
        }
    }

    // MARK: - UserDefaults

    func updateDefaults() {
        let count = UserDefaults.standard.integer(forKey: "app.launchCount") + 1
        UserDefaults.standard.set(count, forKey: "app.launchCount")
        UserDefaults.standard.set(Date(), forKey: "app.lastAction")
        UserDefaults.standard.set(isLoggedIn ? currentUser : "none", forKey: "app.activeUser")
        #if DEBUG
        Apus.shared.log("UserDefaults updated (launchCount: \(count))", level: "debug", source: "Preferences")
        #endif
    }

    // MARK: - Memory

    func allocateMemory() {
        let buffer = Data(repeating: 0xAB, count: 5 * 1024 * 1024) // 5MB
        memoryBuffers.append(buffer)
        #if DEBUG
        let totalMB = memoryBuffers.count * 5
        Apus.shared.log("Allocated 5MB buffer (total retained: \(totalMB)MB, \(memoryBuffers.count) buffers)", level: "info", source: "Memory")
        #endif
    }
}

struct User: Identifiable {
    let id = UUID()
    let name: String
    let email: String
    let role: String
    let loginCount: Int
}
