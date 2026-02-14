import Foundation
#if DEBUG
import Apus
#endif

class AppState: ObservableObject {
    @Published var users: [User] = []
    @Published var selectedTab: Int = 0
    @Published var isLoggedIn: Bool = false
    @Published var currentUser: String = ""

    init() {
        // Sample data
        users = [
            User(name: "Ivan Alvarez", email: "ivan@example.com", role: "Admin", loginCount: 42),
            User(name: "Ana Garcia", email: "ana@example.com", role: "Editor", loginCount: 15),
            User(name: "Carlos Lopez", email: "carlos@example.com", role: "Viewer", loginCount: 3),
        ]

        // Set some UserDefaults
        UserDefaults.standard.set("ivan@example.com", forKey: "app.lastUser")
        UserDefaults.standard.set(true, forKey: "app.onboardingDone")
        UserDefaults.standard.set(7, forKey: "app.launchCount")
        UserDefaults.standard.set(Date(), forKey: "app.lastLaunch")
        UserDefaults.standard.set("dark", forKey: "app.theme")
    }

    func login(as user: User) {
        currentUser = user.email
        isLoggedIn = true
        UserDefaults.standard.set(user.email, forKey: "app.lastUser")

        #if DEBUG
        Apus.shared.log("User logged in: \(user.email)", level: "info", source: "Auth")
        Apus.shared.register(user, id: "currentUser")
        #endif
    }

    func logout() {
        #if DEBUG
        Apus.shared.log("User logged out: \(currentUser)", level: "info", source: "Auth")
        #endif

        currentUser = ""
        isLoggedIn = false
    }

    func fetchSomething() {
        #if DEBUG
        Apus.shared.log("Fetching data from API...", level: "debug", source: "Network")
        #endif

        // This request will be captured by the network interceptor
        let url = URL(string: "https://jsonplaceholder.typicode.com/posts/1")!
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                #if DEBUG
                Apus.shared.log("Fetch failed: \(error.localizedDescription)", level: "error", source: "Network")
                #endif
                return
            }
            #if DEBUG
            let size = data?.count ?? 0
            Apus.shared.log("Fetch complete: \(size) bytes", level: "info", source: "Network")
            #endif
        }.resume()
    }
}

struct User: Identifiable {
    let id = UUID()
    let name: String
    let email: String
    let role: String
    let loginCount: Int
}
