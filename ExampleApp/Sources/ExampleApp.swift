import SwiftUI
#if DEBUG
import Apus
#endif

@main
struct ExampleApp: App {
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG
        Apus.shared.start(interceptNetwork: true)
        Apus.shared.log("App launched", level: "info", source: "App")

        // Register actions the AI agent can trigger
        Apus.shared
            .action("clear_user_defaults", description: "Remove all app UserDefaults") {
                let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("app.") }
                keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
                return "Cleared \(keys.count) keys: \(keys.sorted().joined(separator: ", "))"
            }
            .action("reset_onboarding", description: "Reset onboarding flag so it shows again") {
                UserDefaults.standard.set(false, forKey: "app.onboardingDone")
                return "Onboarding reset — will show on next launch"
            }
            .action("simulate_crash_log", description: "Write a fake crash log to test error handling") {
                Apus.shared.log("FATAL: EXC_BAD_ACCESS at 0x00000000", level: "error", source: "CrashReporter")
                Apus.shared.log("Stack trace: AppState.login() -> UserManager.validate() -> nil dereference", level: "error", source: "CrashReporter")
                return "Crash log simulated — check get_logs for details"
            }
            .action("generate_test_data", description: "Create sample files in Documents directory") {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                for i in 1...3 {
                    let content = "Sample file #\(i)\nGenerated at \(Date())"
                    try content.write(to: docs.appendingPathComponent("sample_\(i).txt"), atomically: true, encoding: .utf8)
                }
                return "Created 3 sample files in Documents/"
            }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .apusInspectable(appState, id: "appState")
        }
    }
}
