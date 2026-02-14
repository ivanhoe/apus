import SwiftUI
#if DEBUG
import Apus
#endif

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            UsersTab()
                .tabItem { Label("Users", systemImage: "person.3") }
                .tag(0)

            LogsTab()
                .tabItem { Label("Actions", systemImage: "bolt.fill") }
                .tag(1)

            InfoTab()
                .tabItem { Label("Info", systemImage: "info.circle") }
                .tag(2)
                .apusInspectable(id: "selectedTab") { [weak appState] in appState?.selectedTab }
        }
        .onChange(of: appState.selectedTab) { [oldValue = appState.selectedTab] newValue in
            #if DEBUG
            let tabs = ["Users", "Actions", "Info"]
            Apus.shared.log("Tab changed to: \(tabs[newValue])", level: "debug", source: "UI")
            #endif
        }
    }
}

// MARK: - Users Tab

struct UsersTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            List(appState.users) { user in
                Button {
                    appState.login(as: user)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(user.name).font(.headline)
                            Text(user.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(user.role)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.blue.opacity(0.1))
                            .clipShape(Capsule())
                        if appState.currentUser == user.email {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Users")
            .toolbar {
                if appState.isLoggedIn {
                    Button("Logout") {
                        appState.logout()
                    }
                }
            }
        }
    }
}

// MARK: - Actions Tab

struct LogsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var actionLog: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Generate Activity") {
                    Button("Fetch API Data") {
                        appState.fetchSomething()
                        actionLog.append("API fetch triggered")
                    }

                    Button("Log Warning") {
                        #if DEBUG
                        Apus.shared.log("Manual warning from user", level: "warning", source: "UserAction")
                        #endif
                        actionLog.append("Warning logged")
                    }

                    Button("Log Error") {
                        #if DEBUG
                        Apus.shared.log("Simulated error: database connection timeout", level: "error", source: "Database")
                        #endif
                        actionLog.append("Error logged")
                    }

                    Button("Write File") {
                        writeTestFile()
                        actionLog.append("File written")
                    }

                    Button("Update UserDefaults") {
                        let count = UserDefaults.standard.integer(forKey: "app.launchCount") + 1
                        UserDefaults.standard.set(count, forKey: "app.launchCount")
                        UserDefaults.standard.set(Date(), forKey: "app.lastAction")
                        #if DEBUG
                        Apus.shared.log("Launch count updated to \(count)", level: "debug", source: "Preferences")
                        #endif
                        actionLog.append("UserDefaults updated (count: \(count))")
                    }
                }

                if !actionLog.isEmpty {
                    Section("Activity Log") {
                        ForEach(actionLog.reversed(), id: \.self) { entry in
                            Text(entry)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Actions")
        }
    }

    private func writeTestFile() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent("test-data.json")
        let data: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": "1.0.0",
            "items": ["alpha", "beta", "gamma"]
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            try? json.write(to: fileURL)
            #if DEBUG
            Apus.shared.log("Wrote test file: \(fileURL.lastPathComponent)", level: "info", source: "FileSystem")
            #endif
        }
    }
}

// MARK: - Info Tab

struct InfoTab: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Apus MCP Server") {
                    LabeledContent("Server", value: "http://localhost:9847")
                    LabeledContent("Endpoint", value: "/mcp")
                    LabeledContent("Protocol", value: "JSON-RPC 2.0")
                }

                Section("Available Tools") {
                    Group {
                        Text("get_logs").font(.caption.monospaced())
                        Text("get_user_defaults").font(.caption.monospaced())
                        Text("get_memory_stats").font(.caption.monospaced())
                        Text("execute_action").font(.caption.monospaced())
                        Text("browse_files / read_file").font(.caption.monospaced())
                        Text("inspect_object").font(.caption.monospaced())
                        Text("get_view_hierarchy").font(.caption.monospaced())
                        Text("get_network_history").font(.caption.monospaced())
                        Text("get_keychain_items").font(.caption.monospaced())
                    }
                }

                Section("Connect Your Editor") {
                    Text("Add to .mcp.json:")
                        .font(.headline)
                    Text("""
                    {"mcpServers":{"apus":{"type":"http","url":"http://localhost:9847/mcp"}}}
                    """)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Info")
        }
    }
}
