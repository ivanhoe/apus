# Apus

**Runtime intelligence for iOS apps, exposed via MCP.**

Apus embeds a lightweight [MCP](https://modelcontextprotocol.io) server inside your iOS app during development. AI agents (Claude Code, Cursor, Windsurf, VS Code Copilot) connect to it and inspect your app's runtime state — logs, network traffic, CoreData, UserDefaults, view hierarchy, and more — without leaving the editor.

Think of it as giving your AI assistant eyes into your running app.

```
┌──────────────────┐         ┌──────────────────────────────────┐
│                  │         │  Your iOS App (Debug Build)      │
│  AI Agent        │         │                                  │
│  (Claude Code,   │  HTTP   │  ┌────────────────────────────┐  │
│   Cursor, etc.)  │◄───────►│  │  Apus MCP Server           │  │
│                  │  :9847  │  │  Runtime tools + actions   │  │
│  "Why is the     │         │  │  JSON-RPC 2.0              │  │
│   login failing?"│         │  └────────────────────────────┘  │
│                  │         │                                  │
└──────────────────┘         └──────────────────────────────────┘
```

---

## Quick Start

Fastest path (5 minutes, simulator + editor + first successful call):

1. **Add the package**
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ivanhoe/apus.git", from: "0.2.0")
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/ivanhoe/apus.git`

2. **Start Apus in DEBUG**  
   (`interceptNetwork: true` enables `get_network_history` from day one)
```swift
import Apus

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Apus.shared.start(interceptNetwork: true)
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

3. **Connect your editor**  
   Create `.mcp.json` in your project root:
```json
{
  "mcpServers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

4. **Run and verify connectivity**
- Run your app in a **Debug build** (recommended: iOS Simulator).
- Open `http://localhost:9847/` and confirm you see `Apus MCP Server` and `Status: Running`.

5. **Ask your first question**
- _"Run `get_diagnostics` and summarize the top issues."_
- _"Show me recent error logs."_
- _"Show failed network requests from the last minute."_

---

## Tools

Apus exposes MCP tools your AI agent can call to inspect runtime state.
Tool availability depends on platform and configuration.

### Always Available (Default)

| Tool | Description |
|------|-------------|
| **`get_diagnostics`** | One-call health summary (app info, memory, errors, network, config). Start here. |
| **`get_logs`** | Recent app logs with filtering by level, keyword, and count |
| **`get_memory_stats`** | Physical footprint, peak memory, heap stats, available system memory |
| **`execute_action`** | Run developer-registered actions (clear cache, reset state, etc.) |
| **`get_app_info`** | Bundle ID, version, build config, loaded frameworks, environment |
| **`list_classes`** | Enumerate ObjC runtime classes, inspect properties and methods |
| **`get_user_defaults`** | All UserDefaults key-value pairs, filterable by prefix |
| **`browse_files`** | List files in the app sandbox with sizes and dates |
| **`read_file`** | Read file contents (text or base64 for binary) |
| **`inspect_object`** | Inspect registered objects via Swift Mirror reflection |
| **`get_keychain_items`** | List keychain items (metadata only, secrets redacted) |

### Project Source Files (auto-detected)

These tools are available when Apus detects a project root (directory containing `.xcodeproj` or `Package.swift`):

| Tool | Description |
|------|-------------|
| **`read_project_file`** | Read source files relative to the project root, with line numbers and optional line range |
| **`edit_project_file`** | Find-and-replace in source files (rejects ambiguous matches with >1 occurrence) |

### Debug-only (Simulator-focused)

| Tool | Description |
|------|-------------|
| **`hot_reload`** | Compile Swift source and inject it into the running app (~4s). Accepts `source_code` directly, returns a screenshot of the result. |

### iOS Only

| Tool | Description |
|------|-------------|
| **`get_screenshot`** | Capture a PNG screenshot of the current screen |
| **`get_view_hierarchy`** | UIKit view tree with types, frames, accessibility info |

### With CoreData

| Tool | Description |
|------|-------------|
| **`inspect_core_data`** | Browse entities and fetch records with NSPredicate filtering |
| **`execute_fetch_request`** | Full-control fetch requests (read-only) |

### With SwiftData (iOS 17+)

| Tool | Description |
|------|-------------|
| **`inspect_swift_data`** | Inspect model schemas, attributes, and relationships |

### With Network Interception

| Tool | Description |
|------|-------------|
| **`get_network_history`** | Request/response history with headers, bodies, status codes, timing (`start(interceptNetwork: true)`) |

---

## Integration Examples

### With CoreData

```swift
#if DEBUG
Apus.shared.start(
    coreDataContext: persistenceController.container.viewContext
)
#endif
```

Now the agent can run queries like:

> _"Show me all User records where lastLogin is older than 7 days"_

### With Network Monitoring

```swift
#if DEBUG
Apus.shared.start(interceptNetwork: true)
#endif
```

> _"What API calls failed in the last minute?"_

### With Object Inspection

```swift
#if DEBUG
Apus.shared.register(viewModel, id: "loginVM")
Apus.shared.register(appState, id: "appState")
#endif
```

> _"What's the current state of the login view model?"_

### With SwiftUI

**Property wrapper** — auto-registers and updates on changes:

```swift
struct ProfileView: View {
    @Inspectable("profileVM") var viewModel = ProfileViewModel()

    var body: some View {
        Text(viewModel.name)
    }
}
```

**View modifier** — register on appear, unregister on disappear:

```swift
ContentView()
    .apusInspectable(appState, id: "appState")
```

### With Actions (your "eval" for Swift)

Register closures the AI agent can discover and execute:

```swift
#if DEBUG
Apus.shared
    .action("clear_cache", description: "Clear URL and image caches") {
        URLCache.shared.removeAllCachedResponses()
        ImageCache.shared.clear()
        return "Cache cleared"
    }
    .action("reset_onboarding", description: "Reset onboarding so it shows again") {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    .action("force_logout", description: "Clear auth tokens and force logout") {
        AuthManager.shared.clearTokens()
        return "Logged out — restart the app"
    }
#endif
```

> _"Clear the cache and check if the images load correctly now"_

### Built-in Actions (zero code)

Apus ships with 10 built-in actions that work in any app without writing a single line of action code:

| Action | What it does |
|--------|-------------|
| `clear_url_cache` | Clear the shared URL cache (images, API responses) |
| `clear_cookies` | Delete all HTTP cookies |
| `clear_tmp` | Delete all files in the app's tmp directory |
| `set_user_default` | Set a UserDefaults value by key |
| `delete_user_default` | Remove a key from UserDefaults |
| `clear_all_user_defaults` | Remove all app-specific UserDefaults (preserves system keys) |
| `delete_file` | Delete a file from the app sandbox |
| `write_file` | Write text content to a file in the sandbox |
| `open_url` | Open a URL or deep link (iOS) |
| `set_appearance` | Switch dark/light/system appearance (iOS) |

These are available immediately — just `Apus.shared.start()`:

> _"Switch the app to dark mode"_
> _"Set UserDefaults key 'app.theme' to 'blue'"_
> _"Clear all cookies and the URL cache"_

### Hot Reload (Simulator)

Apus can compile Swift source code and inject it into the running app without restarting — live UI changes in ~4 seconds.

**Setup** — add these build flags to your target:

```
OTHER_LDFLAGS = $(inherited) -Xlinker -interposable
ENABLE_DEBUG_DYLIB = NO
```

**SwiftUI integration** — mark views for hot reload:

```swift
import Apus

struct MyView: View {
    @ObserveInjection var forceReload  // Forces re-render on injection

    var body: some View {
        Text("Hello!")
            .enableInjection()  // Type erasure for SwiftUI diffing
    }
}
```

**Full workflow** — the agent can read, edit, and reload in one flow:

1. `read_project_file` — read the current source
2. `edit_project_file` — apply changes
3. `hot_reload(source_code:)` — compile, inject, and get a screenshot of the result

**Limitations:**
- Simulator only (requires writable memory)
- Only self-contained structs (no dependencies on types defined in other app files)
- The module name in the dylib must match the app's module name

> _"Change the background color to blue using hot reload"_

### Automatic Log Capture (zero code)

By default, Apus captures **all** output from your app automatically:

- **`os_log` / `Logger`** — polled every 2 seconds via OSLogStore (iOS 15+)
- **`print()` / `NSLog()`** — captured via stdout/stderr pipe interception

These appear in `get_logs` alongside manual entries, tagged with source `"system"`. No setup required — just call `start()`.

To disable (e.g., if it conflicts with your logging pipeline):

```swift
Apus.shared.start(captureSystemLogs: false)
// or via configuration:
Apus.shared.start(configuration: ApusConfiguration(disableSystemLogCapture: true))
```

### Structured Logging

For richer, categorized logs, use the manual API:

```swift
Apus.shared.log("Token refresh failed: 401", level: "error", source: "AuthService")
Apus.shared.log("Cart updated: 3 items", level: "info", source: "CartManager")
```

> _"Show me all error logs from AuthService"_

### Memory Diagnostics

Zero configuration — always available:

> _"How much memory is the app using? Is there a leak?"_

Returns physical footprint, peak, resident size, heap stats, and available system memory.

### Full Configuration

```swift
#if DEBUG
Apus.shared.start(
    port: 9847,
    coreDataContext: container.viewContext,
    interceptNetwork: true,
    captureSystemLogs: true,  // OSLog + print/NSLog capture (default: true)
    configuration: ApusConfiguration(
        bindAddress: "127.0.0.1",                  // network interface (default: localhost only)
        enabledTools: ["get_logs", "get_screenshot"], // allow-list (nil = all tools)
        disabledTools: ["get_keychain_items"],      // exclude specific tools
        disableSystemLogCapture: false              // disable OSLog/stderr capture via config
    )
)
#endif
```

---

## Editor Setup

### Claude Code

Create `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

### Cursor

In Cursor Settings → MCP Servers, add:

```json
{
  "apus": {
    "url": "http://localhost:9847/mcp"
  }
}
```

### VS Code (GitHub Copilot)

In `.vscode/mcp.json`:

```json
{
  "servers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

### Claude Desktop

In `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apus": {
      "type": "http",
      "url": "http://localhost:9847/mcp"
    }
  }
}
```

---

## Troubleshooting (60 seconds)

### Agent cannot connect to Apus

- Confirm the app is running in **Debug** and calls `Apus.shared.start(...)`.
- Open `http://localhost:9847/` and verify `Status: Running`.
- If you changed the port, update your MCP URL to match it.

### `get_network_history` is empty

- Start Apus with `interceptNetwork: true`.
- If you use custom sessions, use `Apus.shared.monitoredURLSession`.

### Running on a physical iPhone

- Easiest first setup is iOS Simulator.
- Default bind address is `127.0.0.1`, so host/editor access is local-only by design.

### Missing tools you expected

- `get_screenshot` / `get_view_hierarchy` are iOS-only.
- CoreData/SwiftData tools appear only when you pass a context/container to `start(...)`.

---

## What Can You Do With This?

Once connected, you can ask your AI agent things like:

- _"Take a screenshot — what does the user see right now?"_
- _"The login screen shows a blank white page — what's in the view hierarchy?"_
- _"What API calls is the app making when I tap refresh?"_
- _"Show me the last 20 error logs"_
- _"How much memory is the app using right now?"_
- _"Clear the cache and check if that fixes the loading issue"_
- _"What's stored in UserDefaults right now?"_
- _"Query the database for users created today"_
- _"What files are in the Documents directory?"_
- _"Inspect the appState object — is the user logged in?"_

The agent reads the runtime state, correlates it with your source code, and gives you answers or fixes — without you manually setting breakpoints, printing variables, or switching between Xcode and your editor.

---

## Security

Apus is designed exclusively for development:

| Layer | Protection |
|-------|------------|
| **Build config** | Call `Apus.shared.start(...)` only inside `#if DEBUG` |
| **Network** | HTTP server binds to `127.0.0.1` only — no external access |
| **Origin** | Only allows local/VSCode origins; rejects `Origin: null` and external browser origins |
| **Sandbox** | File operations restricted to the app's sandbox with path traversal prevention |
| **Project files** | `read_project_file` / `edit_project_file` scoped to projectRoot, path traversal prevention via `SecurityMiddleware.sanitizePath()` |
| **Read-only** | Inspection tools are read-only. Actions are opt-in and developer-defined. |

---

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [Swifter](https://github.com/httpswift/swifter) | Embedded HTTP server (~2000 LOC, pure Swift) |

That's the only dependency. Everything else uses system frameworks.

---

## Architecture

```
Sources/Apus/
├── Apus.swift                    # Public API (start, stop, register, log, action)
├── Configuration.swift           # ApusConfiguration
├── SwiftUISupport.swift          # @Inspectable, @ObserveInjection, .enableInjection(), .apusInspectable()
├── Server/
│   ├── HTTPServer.swift          # Swifter wrapper, localhost:9847
│   ├── MCPProtocolHandler.swift  # JSON-RPC 2.0 routing
│   ├── MCPMessages.swift         # Protocol constants
│   └── SecurityMiddleware.swift  # IP + origin validation
├── Tools/
│   ├── MCPTool.swift             # Tool protocol
│   ├── ToolRegistry.swift        # Registration + dispatch
│   ├── LogCapture.swift          # Circular buffer log capture
│   ├── NetworkInterceptor.swift  # URLProtocol-based capture
│   ├── CoreDataInspector.swift   # NSFetchRequest builder
│   ├── SwiftDataInspector.swift  # ModelContainer schema reader
│   ├── ViewHierarchyInspector.swift  # UIWindow tree walker
│   ├── UserDefaultsReader.swift  # UserDefaults dump
│   ├── KeychainReader.swift      # SecItemCopyMatching queries
│   ├── FileBrowser.swift         # Sandbox file listing + reading
│   ├── ObjectInspector.swift     # Mirror-based reflection
│   ├── MemoryInspector.swift     # task_info + malloc stats
│   ├── ActionRunner.swift        # Developer-registered closures
│   ├── BuiltInActions.swift      # 10 zero-code actions (cache, defaults, files, UI)
│   ├── AppInfoInspector.swift    # Bundle, plist, frameworks, environment
│   ├── ClassInspector.swift      # ObjC runtime class enumeration
│   ├── DiagnosticsTool.swift     # One-call app health summary
│   ├── HotReloadTool.swift       # Compile + inject Swift source via dylib (DEBUG)
│   ├── ProjectFileTools.swift    # Read/edit project source files (scoped to projectRoot)
│   └── ScreenshotCapture.swift   # UIWindow screenshot (iOS)
├── CHotReload/                   # C target for runtime symbol rebinding
│   ├── fishhook.c / .h           # Facebook's fishhook — patches GOT entries
│   ├── interpose.c               # Symbol interposition helpers
│   └── popen_wrapper.c           # C bridge for popen() (unavailable in Swift/iOS)
└── Utilities/
    ├── CircularBuffer.swift      # Thread-safe ring buffer (logs, network)
    ├── OSLogReader.swift          # OSLogStore polling (os_log/Logger capture)
    ├── StderrCapture.swift        # stdout/stderr pipe interception (print/NSLog capture)
    ├── MirrorHelper.swift         # Reflection helpers
    └── JSONHelper.swift           # Serialization
```

---

## Why "Apus"?

_Apus apus_ is the scientific name for the common swift — a bird that spends almost its entire life airborne. It eats, sleeps, and mates in flight. It never needs to land.

Like the bird, Apus observes your app continuously while it runs, without ever interrupting it.

---

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
