import SwiftUI
#if DEBUG
import Apus
#endif

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            PlaygroundTab()
                .tabItem { Label("Playground", systemImage: "play.circle.fill") }
                .tag(0)

            SetupTab()
                .tabItem { Label("Setup", systemImage: "link") }
                .tag(1)
        }
        .preferredColorScheme(.dark)
        .onChange(of: appState.selectedTab) { newValue in
            #if DEBUG
            let tabs = ["Playground", "Setup"]
            if newValue < tabs.count {
                Apus.shared.log("Tab changed to: \(tabs[newValue])", level: "debug", source: "UI")
            }
            #endif
        }
    }
}

// MARK: - Playground Tab

struct PlaygroundTab: View {
    @EnvironmentObject var appState: AppState
    @State private var activityLog: [ActivityEntry] = []

    var body: some View {
        NavigationStack {
            List {
                // Status banner
                ApusStatusBanner()

                // Users
                Section {
                    ForEach(appState.users) { user in
                        UserRow(user: user, isSelected: appState.currentUser == user.email) {
                            appState.login(as: user)
                            log("Logged in as \(user.name)", icon: "person.fill")
                        }
                    }

                    if appState.isLoggedIn {
                        Button(role: .destructive) {
                            let name = appState.currentUser
                            appState.logout()
                            log("Logged out (\(name))", icon: "rectangle.portrait.and.arrow.right")
                        } label: {
                            Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                } header: {
                    SectionHeader("Users", subtitle: "inspect_object, get_logs")
                } footer: {
                    Text("Try: \"What's the current state of appState?\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Network
                Section {
                    ActionButton("Fetch Posts", icon: "arrow.down.circle", color: .blue) {
                        appState.fetchAPI(endpoint: "posts/1")
                        log("Fetching /posts/1", icon: "arrow.down.circle")
                    }

                    ActionButton("Fetch Users", icon: "person.2", color: .blue) {
                        appState.fetchAPI(endpoint: "users")
                        log("Fetching /users", icon: "person.2")
                    }

                    ActionButton("Fetch 404 (Error)", icon: "exclamationmark.triangle", color: .orange) {
                        appState.fetchAPI(endpoint: "nonexistent/999")
                        log("Fetching /nonexistent/999 (will 404)", icon: "exclamationmark.triangle")
                    }
                } header: {
                    SectionHeader("Network", subtitle: "get_network_history")
                } footer: {
                    Text("Try: \"What API calls failed recently?\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Logs
                Section {
                    ActionButton("Log Info", icon: "info.circle", color: .blue) {
                        #if DEBUG
                        Apus.shared.log("User tapped the info button", level: "info", source: "UserAction")
                        #endif
                        log("Info logged", icon: "info.circle")
                    }

                    ActionButton("Log Warning", icon: "exclamationmark.triangle", color: .yellow) {
                        #if DEBUG
                        Apus.shared.log("Cache is 92% full, consider clearing", level: "warning", source: "Cache")
                        #endif
                        log("Warning logged", icon: "exclamationmark.triangle")
                    }

                    ActionButton("Log Error", icon: "xmark.octagon", color: .red) {
                        #if DEBUG
                        Apus.shared.log("Database connection timeout after 30s", level: "error", source: "Database")
                        Apus.shared.log("Retry attempt 1/3 failed", level: "error", source: "Database")
                        #endif
                        log("Error logged (2 entries)", icon: "xmark.octagon")
                    }
                } header: {
                    SectionHeader("Logs", subtitle: "get_logs")
                } footer: {
                    Text("Try: \"Show me all error logs from Database\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Files & Defaults
                Section {
                    ActionButton("Write Test File", icon: "doc.badge.plus", color: .green) {
                        appState.writeTestFile()
                        log("Wrote test-data.json", icon: "doc.badge.plus")
                    }

                    ActionButton("Update UserDefaults", icon: "slider.horizontal.3", color: .purple) {
                        appState.updateDefaults()
                        log("UserDefaults updated", icon: "slider.horizontal.3")
                    }

                    ActionButton("Allocate Memory", icon: "memorychip", color: .indigo) {
                        appState.allocateMemory()
                        log("Allocated 5MB buffer", icon: "memorychip")
                    }
                } header: {
                    SectionHeader("Storage & Memory", subtitle: "browse_files, get_user_defaults, get_memory_stats")
                } footer: {
                    Text("Try: \"How much memory is the app using?\"")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Activity log
                if !activityLog.isEmpty {
                    Section {
                        ForEach(activityLog.reversed()) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.icon)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Button("Clear Log") {
                            activityLog.removeAll()
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    } header: {
                        Text("Activity")
                    }
                }
            }
            .navigationTitle("Playground")
        }
    }

    private func log(_ message: String, icon: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        activityLog.append(ActivityEntry(
            message: message,
            icon: icon,
            time: formatter.string(from: Date())
        ))
    }
}

// MARK: - Setup Tab

struct SetupTab: View {
    @State private var copied = false

    private let mcpConfig = """
    {
      "mcpServers": {
        "apus": {
          "type": "http",
          "url": "http://localhost:9847/mcp"
        }
      }
    }
    """

    var body: some View {
        NavigationStack {
            List {
                ApusStatusBanner()

                // Connection
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Add to `.mcp.json` in your project root:")
                            .font(.subheadline)

                        Text(mcpConfig)
                            .font(.system(.caption, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button {
                            UIPasteboard.general.string = mcpConfig
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied!" : "Copy Config", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(copied ? .green : .blue)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Connect Your Editor")
                }

                // Tools
                Section {
                    ToolRow("get_logs", desc: "App logs filtered by level, keyword, count")
                    ToolRow("get_memory_stats", desc: "Physical footprint, heap, system memory")
                    ToolRow("execute_action", desc: "Run registered actions (14 built-in)")
                    ToolRow("get_app_info", desc: "Bundle, version, config, frameworks")
                    ToolRow("list_classes", desc: "ObjC runtime class inspection")
                    ToolRow("get_user_defaults", desc: "All UserDefaults key-value pairs")
                    ToolRow("browse_files", desc: "Sandbox file listing with sizes")
                    ToolRow("read_file", desc: "File contents (text or base64)")
                    ToolRow("inspect_object", desc: "Registered objects via Mirror")
                    ToolRow("get_keychain_items", desc: "Keychain metadata (secrets redacted)")
                    ToolRow("get_screenshot", desc: "PNG screenshot of current screen")
                    ToolRow("get_view_hierarchy", desc: "UIKit view tree + accessibility")
                    ToolRow("get_network_history", desc: "Request/response history + timing")
                } header: {
                    Text("Available Tools (13)")
                } footer: {
                    Text("CoreData and SwiftData tools are available when you pass a context/container to start().")
                        .font(.caption2)
                }

                // Try asking
                Section {
                    TryAskingRow("Take a screenshot — what does the user see?")
                    TryAskingRow("Show me the last 20 error logs")
                    TryAskingRow("How much memory is the app using?")
                    TryAskingRow("What API calls failed recently?")
                    TryAskingRow("Clear all cookies and the URL cache")
                    TryAskingRow("Switch the app to dark mode")
                    TryAskingRow("What's stored in UserDefaults?")
                    TryAskingRow("Inspect the appState object")
                } header: {
                    Text("Try Asking Your Agent")
                }
            }
            .navigationTitle("Setup")
        }
    }
}

// MARK: - Reusable Components

struct ApusStatusBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
                .shadow(color: .green.opacity(0.5), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("Apus MCP Server")
                    .font(.subheadline.weight(.semibold))
                Text("http://localhost:9847/mcp")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Running")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.green.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    init(_ title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.caption2.monospaced())
                .foregroundStyle(.blue)
        }
    }
}

struct UserRow: View {
    let user: User
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Circle()
                    .fill(colorForRole(user.role))
                    .frame(width: 36, height: 36)
                    .overlay {
                        Text(String(user.name.prefix(1)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(user.name).font(.subheadline.weight(.medium))
                    Text(user.email).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Text(user.role)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(colorForRole(user.role).opacity(0.12))
                    .foregroundStyle(colorForRole(user.role))
                    .clipShape(Capsule())

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .tint(.primary)
    }

    private func colorForRole(_ role: String) -> Color {
        switch role {
        case "Admin": return .red
        case "Editor": return .blue
        default: return .gray
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    init(_ title: String, icon: String, color: Color, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(color)
        }
    }
}

struct ToolRow: View {
    let name: String
    let desc: String

    init(_ name: String, desc: String) {
        self.name = name
        self.desc = desc
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline.monospaced().weight(.medium))
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct TryAskingRow: View {
    let prompt: String
    @State private var copied = false

    init(_ prompt: String) {
        self.prompt = prompt
    }

    var body: some View {
        Button {
            UIPasteboard.general.string = prompt
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: copied ? "checkmark.circle.fill" : "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .blue.opacity(0.6))
                    .frame(width: 16)
                Text(prompt)
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(copied ? .green : .primary)
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Color.green : Color.secondary.opacity(0.5))
            }
        }
        .tint(.primary)
        .padding(.vertical, 2)
    }
}

// MARK: - Models

struct ActivityEntry: Identifiable {
    let id = UUID()
    let message: String
    let icon: String
    let time: String
}
