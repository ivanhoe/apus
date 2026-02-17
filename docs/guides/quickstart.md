# Quickstart

Fastest path (about 5 minutes): add Apus, run the app in Debug, connect your editor, and run your first MCP tool.

## 1) Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ivanhoe/apus.git", from: "0.2.0")
]
```

Or in Xcode: File -> Add Package Dependencies -> `https://github.com/ivanhoe/apus.git`.

## 2) Start Apus in `DEBUG`

`interceptNetwork: true` enables `get_network_history` immediately.

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

## 3) Connect your editor

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

Editor-specific setups are in [Editor setup](editor-setup.md).

## 4) Verify connectivity

- Run your app in a Debug build (recommended: iOS Simulator).
- Open `http://localhost:9847/`.
- Confirm it shows `Apus MCP Server` and `Status: Running`.

## 5) Run first prompts

- "Run `get_diagnostics` and summarize the top issues."
- "Show me recent error logs."
- "Show failed network requests from the last minute."

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+
