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
│                  │  :9847  │  │  11 inspection tools        │  │
│  "Why is the     │         │  │  JSON-RPC 2.0               │  │
│   login failing?"│         │  └────────────────────────────┘  │
│                  │         │                                  │
└──────────────────┘         └──────────────────────────────────┘
```

---

## Quick Start

**1. Add the package**

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ivanhoe/apus.git", from: "0.1.0")
]
```

Or in Xcode: File → Add Package Dependencies → `https://github.com/ivanhoe/apus.git`

**2. Start the server (2 lines)**

```swift
import Apus

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Apus.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

**3. Connect your editor**

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

That's it. Ask your AI agent _"what are the recent logs?"_ and it will call Apus automatically.

---

## Tools

Apus exposes 11 MCP tools that AI agents can call to inspect your running app:

### Always Available

| Tool | Description |
|------|-------------|
| **`get_logs`** | Recent app logs with filtering by level, keyword, and count |
| **`get_user_defaults`** | All UserDefaults key-value pairs, filterable by prefix |
| **`browse_files`** | List files in the app sandbox with sizes and dates |
| **`read_file`** | Read file contents (text or base64 for binary) |
| **`inspect_object`** | Inspect registered objects via Swift Mirror reflection |
| **`get_keychain_items`** | List keychain items (metadata only, secrets redacted) |

### iOS Only

| Tool | Description |
|------|-------------|
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
| **`get_network_history`** | Request/response history with headers, bodies, status codes, timing |

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

### Structured Logging

```swift
Apus.shared.log("Token refresh failed: 401", level: "error", source: "AuthService")
Apus.shared.log("Cart updated: 3 items", level: "info", source: "CartManager")
```

> _"Show me all error logs from AuthService"_

### Full Configuration

```swift
#if DEBUG
Apus.shared.start(
    port: 9847,
    coreDataContext: container.viewContext,
    interceptNetwork: true,
    configuration: ApusConfiguration(
        disabledTools: ["get_keychain_items"]  // exclude specific tools
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

## What Can You Do With This?

Once connected, you can ask your AI agent things like:

- _"The login screen shows a blank white page — what's in the view hierarchy?"_
- _"What API calls is the app making when I tap refresh?"_
- _"Show me the last 20 error logs"_
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
| **Compilation** | All code wrapped in `#if DEBUG` — zero footprint in release builds |
| **Network** | HTTP server binds to `127.0.0.1` only — no external access |
| **Origin** | Validates request origin headers to prevent CSRF |
| **Sandbox** | File operations restricted to the app's sandbox with path traversal prevention |
| **Read-only** | No tools modify state — inspection only |

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
├── Apus.swift                    # Public API (start, stop, register, log)
├── Configuration.swift           # ApusConfiguration
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
│   └── ObjectInspector.swift     # Mirror-based reflection
└── Utilities/
    ├── CircularBuffer.swift      # Ring buffer (logs, network)
    ├── MirrorHelper.swift        # Reflection helpers
    └── JSONHelper.swift          # Serialization
```

---

## Why "Apus"?

_Apus apus_ is the scientific name for the common swift — a bird that spends almost its entire life airborne. It eats, sleeps, and mates in flight. It never needs to land.

Like the bird, Apus observes your app continuously while it runs, without ever interrupting it.

---

## License

Apache 2.0 — see [LICENSE](LICENSE) for details.
