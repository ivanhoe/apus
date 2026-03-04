# GEMINI.md — Apus

## What is Apus?

Runtime MCP server embedded in iOS/macOS apps during development. AI agents inspect live app state (logs, network, view hierarchy, storage, screenshots) over localhost HTTP without leaving the editor. Swift Package, zero external dependencies.

## Architecture

```text
Sources/
├── Apus/
│   ├── Apus.swift              # Entry point, singleton
│   ├── Configuration.swift     # Runtime config
│   ├── SwiftUISupport.swift    # SwiftUI integration
│   ├── Server/
│   │   ├── HTTPServer.swift         # HTTP server (port 9847)
│   │   ├── WebSocketServer.swift    # WebSocket server (port 9848)
│   │   ├── MCPProtocolHandler.swift # JSON-RPC MCP handler
│   │   ├── MCPMessages.swift        # MCP message types
│   │   └── SecurityMiddleware.swift # Request validation
│   ├── Tools/                  # MCP tools (one file per tool)
│   │   ├── MCPTool.swift       # Protocol all tools conform to
│   │   ├── ToolRegistry.swift  # Discovery & dispatch
│   │   ├── UIInteractionTool.swift  # ui_interact: tap/swipe/type
│   │   └── ...                 # ~20 tool implementations
│   └── Utilities/              # Helpers (CircularBuffer, JSON, mirror)
├── CHotReload/                 # C bridging for hot reload (fishhook)
└── Demo/                       # CLI demo target
ExampleApp/                     # SwiftUI example app (XcodeGen)
Tests/ApusTests/                # Unit tests
vscode-extension/               # VS Code extension (TypeScript/esbuild)
```

## Tech Stack

- **Swift 5.9+**, iOS 16+ / macOS 13+
- **Swift Package Manager** — zero external dependencies, keep it that way
- **MCP over HTTP**: JSON-RPC 2.0 on `localhost:9847`
- **MCP over WebSocket**: `ws://localhost:9848` — push subscriptions (logs, network, screenshots)
- **VS Code extension**: TypeScript, esbuild, no framework

## Conventions

- One MCP tool per file in `Sources/Apus/Tools/`
- Every tool conforms to `MCPTool` protocol
- Register new tools in `ToolRegistry.swift`
- `#if DEBUG` guards everywhere — never runs in release builds
- HTTP server binds to `127.0.0.1` only, never `0.0.0.0`
- No force unwraps (`!`) in library code
- No `print()` — use `LogCapture` or `os_log`

## Build & Test

```bash
swift build                          # Compile
swift test                           # Run tests
cd vscode-extension && npm run build # Build VS Code extension
./ExampleApp/build-and-run.sh        # Build + launch ExampleApp on simulator
```

## MCP Tool Reference (key tools)

| Tool | Description |
|------|-------------|
| `get_logs` | Recent app logs with level/source filtering |
| `get_view_hierarchy` | UIView tree with frames, identifiers, labels. Supports `format: "json"` for structured output with bounding rects |
| `get_network_history` | Recent HTTP requests (method, URL, status, duration, id) |
| `get_network_request_detail` | Full headers + body for one request by UUID |
| `ui_interact` | Tap, double-tap, long-press, swipe, type_text. Targeting: `identifier` > `label` > `path` > `coordinate: {x, y}` |
| `hot_reload` | Inject modified Swift code at runtime via fishhook |
| `get_diagnostics` | Server health, tool registry, WebSocket connections |

## Current Work (2026-02-25)

### Branch: `feature/ui-interaction-tool` → PR #9 → main

**ui_interact tool** (`Sources/Apus/Tools/UIInteractionTool.swift`):
- `tap`, `double_tap`, `long_press`, `swipe`, `type_text`
- `swipe` handles UIScrollView targets via `contentOffset` fallback
- Coordinate format: `{ "x": 195.0, "y": 422.0 }` nested object

**Interactive Live Preview** (`vscode-extension/src/panels/live-preview-panel.ts`):
- Click/drag/type on screenshot → `callTool("ui_interact", args)` → real action in app
- Coordinate mapping: `device_point = JPEG_pixel / scale` (scale default 0.5)
- Gestures: tap, double-tap, swipe, keyboard input
- Visual feedback: ripple animations, swipe line, toast

**Pending improvement**: Replace raw coordinate targeting with view hierarchy hit-testing.
Call `get_view_hierarchy(format: "json")` → cache → hit-test on click → send `identifier`/`label`/`path`.

## Known Issues

- 2 pre-existing test failures in `JSONHelperTests` (unrelated to current work)
- iOS simulator tests require GitHub Actions macOS runners (CoreSimulator restrictions locally)

## Don'ts

- No external dependencies
- No release build exposure (`#if DEBUG` everywhere)
- No `0.0.0.0` binding
- No secrets in tool responses
- Don't break MCP JSON-RPC contract (stable schemas)
