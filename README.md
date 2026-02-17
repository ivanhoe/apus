# Apus

**Runtime intelligence for iOS apps, exposed via MCP.**

Apus embeds an MCP server inside your app during development. AI agents (Claude Code, Cursor, Copilot, Windsurf) can inspect runtime state like logs, network traffic, app storage, and UI hierarchy without leaving your editor.

Use this page for the shortest setup path. Full detail is in [`docs/`](docs/README.md).

## Quick Start

1. Add the package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ivanhoe/apus.git", from: "0.2.0")
]
```

2. Start Apus in Debug:

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

3. Create `.mcp.json` in your project root:

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

4. Run the app in Debug and verify `http://localhost:9847/` shows `Status: Running`.
5. Ask your agent:
- "Run `get_diagnostics` and summarize the top issues."
- "Show recent error logs."
- "Show failed network requests from the last minute."

## Documentation

| If you need... | Read |
|---|---|
| End-to-end onboarding | [`docs/guides/quickstart.md`](docs/guides/quickstart.md) |
| MCP setup per editor | [`docs/guides/editor-setup.md`](docs/guides/editor-setup.md) |
| Common runtime workflows | [`docs/guides/runtime-workflows.md`](docs/guides/runtime-workflows.md) |
| Full tool list and availability | [`docs/reference/tools.md`](docs/reference/tools.md) |
| Configuration options | [`docs/reference/configuration.md`](docs/reference/configuration.md) |
| Connectivity and runtime issues | [`docs/reference/troubleshooting.md`](docs/reference/troubleshooting.md) |
| Security constraints | [`docs/reference/security.md`](docs/reference/security.md) |
| Internal architecture | [`docs/reference/architecture.md`](docs/reference/architecture.md) |

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+

## Why "Apus"?

_Apus apus_ is the scientific name for the common swift: a bird that spends most of its life in flight. Apus aims for the same idea in debugging: continuous runtime visibility without interrupting flow.

## License

Apache 2.0. See [`LICENSE`](LICENSE).
