# Apus VS Code Extension

Build and debug iOS apps without leaving VS Code. The Apus extension connects to your running app via WebSocket and gives you live preview, UI inspection, log streaming, and one-click build — all inside your editor.

## Why?

Xcode is powerful but heavy. For iterating on UI, inspecting state, and fixing bugs, you don't always need the full IDE. The Apus extension lets you:

- **See your app live** — real-time screenshot stream at up to 15 FPS
- **Touch your app from VS Code** — tap, swipe, type directly on the preview
- **Inspect views in 3D** — Three.js-powered view hierarchy explorer
- **Stream logs in real-time** — filterable, color-coded, no Console.app needed
- **Build with one command** — `Cmd+Shift+P` → "Preview Changes" compiles and deploys
- **Auto-build on save** — optional: save a `.swift` file, app rebuilds automatically

All of this works with any AI agent (Claude Code, GitHub Copilot, Cursor) through the same MCP connection.

## Setup

### 1. Install the Extension

```bash
# From the vscode-extension directory
cd vscode-extension
npm install && npm run build
npx vsce package
code --install-extension apus-0.1.0.vsix
```

### 2. Add Apus to Your App

```swift
// In your App.swift or AppDelegate
#if DEBUG
import Apus
#endif

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Apus.shared.start(
            interceptNetwork: true  // Optional: capture network traffic
        )
        #endif
    }
    // ...
}
```

### 3. Configure Your Build Script

The extension runs a shell script to build and deploy. Create `build-and-run.sh` in your project:

```bash
#!/bin/bash
set -e
SIMULATOR_ID="${SIMULATOR_ID:-YOUR_SIMULATOR_UUID}"
BUNDLE_ID="com.your.app"

xcodegen generate  # if you use XcodeGen
xcodebuild -scheme YourApp \
  -destination "id=${SIMULATOR_ID}" \
  -derivedDataPath build \
  -quiet

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl install "$SIMULATOR_ID" "build/Build/Products/Debug-iphonesimulator/YourApp.app"
xcrun simctl launch "$SIMULATOR_ID" "$BUNDLE_ID"
```

Then point the extension to it in VS Code settings:

```json
{
  "apus.previewChangesScriptPath": "build-and-run.sh"
}
```

### 4. Connect

1. Run your app on the simulator (or use Preview Changes)
2. The extension auto-connects via WebSocket on `ws://localhost:9848`
3. Status bar shows "Apus: Connected" when ready

## Features

### Live Preview

**Command:** `Apus: Show Live Preview`

Real-time screenshot stream of your running app, rendered in a VS Code panel. Click, swipe, and type directly on the image — interactions are sent to the real app via `ui_interact`.

| Gesture | How |
|---------|-----|
| Tap | Click on the preview |
| Double-tap | Double-click |
| Swipe | Click and drag |
| Type text | Focus the preview and type on your keyboard |

The preview uses adaptive FPS: high during interactions (configurable, default 5 FPS), dropping to idle (1 FPS) when you stop interacting.

**Key settings:**

| Setting | Default | Description |
|---------|---------|-------------|
| `apus.screenshotFps` | 5 | Active FPS (1–15) |
| `apus.idleScreenshotFps` | 1 | Idle FPS |
| `apus.screenshotScale` | 2.0 | Image scale (0.01–2.0) |
| `apus.screenshotQuality` | 1.0 | JPEG quality (0–1) |
| `apus.interactionBoostMs` | 2500 | High FPS duration after interaction |

### 3D View Inspector

**Command:** `Apus: Show Inspector`

Exploded 3D view of your app's UIKit view hierarchy, powered by Three.js and `OrbitControls`. Each view layer is rendered as a separate plane — rotate, zoom, and click to identify views by class name, accessibility identifier, and frame.

Includes:
- Screenshot texture on each view layer
- Log and network event streams in side tabs
- Click-to-interact on the 3D scene
- "Preview Changes" button to trigger a build directly from the panel

### Log Viewer

**Command:** `Apus: Show Log Viewer`

Real-time log stream with:
- Level-based filtering (debug, info, warning, error)
- Text search
- Color-coded entries by severity
- Buffer of up to 1000 entries (configurable via `apus.logBufferSize`)

Captures `os_log`, `Logger`, `print()`, and `NSLog` — anything Apus captures in the app.

### Preview Changes (Build & Deploy)

**Command:** `Apus: Preview Changes` | **Shortcut:** `Cmd+Shift+R` | **Status bar:** 🚀 Deploy

The build script (`build-and-run.sh`) supports three modes via a single flag:

| Mode | Command | What it does | When |
|------|---------|-------------|------|
| Full | `./build-and-run.sh` | compile + install + launch | First time / from scratch |
| Build only | `./build-and-run.sh --build` | compile only | On save (Ctrl+S) |
| Deploy only | `./build-and-run.sh --deploy` | install + launch | When you want to see the result |

Features:
- **Smart queue** — manual deploy always has priority; auto-saves are skipped if a build is already running
- **Non-blocking toasts** — notifications never hold up the next queued action
- Timeout with graceful kill (SIGTERM → SIGKILL)
- Progress notification with duration

#### Recommended Setup: Compile on Save, Deploy on Demand

This is the default behavior — **no configuration needed**. The extension ships with these defaults:

| Setting | Default |
|---------|---------|
| `autoPreviewOnSave` | `true` |
| `autoPreviewScriptPath` | `ExampleApp/build-and-run.sh --build` |
| `previewChangesScriptPath` | `ExampleApp/build-and-run.sh --deploy` |
| `autoPreviewShowSuccessNotification` | `true` |

The workflow:

```
 Ctrl+S                          Cmd+Shift+R (or 🚀 Deploy)
    │                                    │
    ▼                                    ▼
 compile only (~5-15s)           install + launch (~1-3s)
    │                                    │
    ▼                                    ▼
 "Build succeeded" toast         App running on simulator
```

- **Save** compiles in the background — you get immediate feedback on errors
- **Deploy** only when you're ready to see the result — no recompilation, just installs and launches
- If you save multiple times during a build, only the first triggers; subsequent saves are skipped
- Deploy always runs, even if queued behind a build

#### File Patterns

Customize which files trigger auto-build on save:

```json
{
  "apus.autoPreviewFileGlobs": [
    "Sources/**/*.swift",
    "YourApp/**/*.swift",
    "Package.swift"
  ]
}
```

## The AI Agent Workflow

The real power is combining the extension with an AI agent. Here's the workflow:

```
You describe what you want
        ↓
AI agent edits Swift files
        ↓
Ctrl+S compiles (~5s) → Cmd+Shift+R deploys (~1s)
        ↓
Live Preview shows the result
        ↓
You give feedback → repeat
```

The AI agent connects to the same Apus MCP server and has access to 20+ tools:

| Tool | What it does |
|------|-------------|
| `get_screenshot` | Capture what the user sees |
| `get_view_hierarchy` | Full UIKit view tree |
| `get_logs` | App logs with filters |
| `get_network_history` | HTTP request/response history |
| `ui_interact` | Tap, swipe, type programmatically |
| `hot_reload` | Compile & inject Swift in ~4s |
| `read_project_file` | Read source files |
| `edit_project_file` | Find-and-replace in source |
| `inspect_object` | Mirror reflection on registered objects |
| `get_memory_stats` | Memory footprint and heap stats |
| `get_diagnostics` | One-call health summary |

The agent can observe the app, make changes, build, and verify — all autonomously.

### Editor-Specific MCP Config

**Claude Code** (`.mcp.json`):
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

**Cursor** (Settings → MCP Servers):
```json
{
  "apus": {
    "url": "http://localhost:9847/mcp"
  }
}
```

**VS Code + GitHub Copilot** (`.vscode/mcp.json`):
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

## All Settings Reference

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `apus.wsHost` | string | `127.0.0.1` | WebSocket host |
| `apus.wsPort` | number | `9848` | WebSocket port |
| `apus.autoConnect` | boolean | `true` | Connect on startup |
| `apus.screenshotFps` | number | `5` | Active screenshot FPS |
| `apus.screenshotScale` | number | `2.0` | Screenshot scale factor |
| `apus.screenshotQuality` | number | `1.0` | JPEG quality |
| `apus.idleScreenshotFps` | number | `1` | Idle FPS |
| `apus.interactionBoostMs` | number | `2500` | High FPS window after interaction |
| `apus.interactionStrictMode` | boolean | `true` | Require semantic targets for touches |
| `apus.logBufferSize` | number | `1000` | Max log entries in memory |
| `apus.reconnectIntervalMs` | number | `5000` | Reconnection interval |
| `apus.previewChangesScriptPath` | string | `ExampleApp/build-and-run.sh --deploy` | Script for manual deploy (`Cmd+Shift+R`) |
| `apus.previewChangesTimeoutSec` | number | `600` | Build timeout |
| `apus.previewChangesRevealOutput` | boolean | `true` | Show output on manual build |
| `apus.autoPreviewOnSave` | boolean | `true` | Auto-build on save |
| `apus.autoPreviewScriptPath` | string | `ExampleApp/build-and-run.sh --build` | Script for auto-compile on save |
| `apus.autoPreviewDebounceMs` | number | `2000` | Debounce before auto-build |
| `apus.autoPreviewCooldownSec` | number | `0` | Min gap between auto-builds |
| `apus.autoPreviewRevealOutput` | boolean | `false` | Show output on auto-build |
| `apus.autoPreviewShowSuccessNotification` | boolean | `true` | Toast on auto-build success |
| `apus.autoPreviewFileGlobs` | string[] | `["**/*.swift", ...]` | File patterns that trigger auto-build |

## Architecture

```
VS Code Extension                          iOS Simulator
┌──────────────────────┐                  ┌──────────────────┐
│  Live Preview Panel  │◄── screenshots ──│                  │
│  Inspector Panel     │◄── hierarchy ────│   Your App       │
│  Log Viewer Panel    │◄── logs ─────────│     +            │
│                      │                  │   Apus SDK       │
│  Preview Changes ────┼── build script ──│                  │
│                      │                  │  HTTP :9847 (MCP) │
│  AI Agent (MCP) ─────┼── JSON-RPC ──────│  WS   :9848      │
└──────────────────────┘                  └──────────────────┘
```

- **Port 9847 (HTTP)**: MCP JSON-RPC endpoint — used by AI agents
- **Port 9848 (WebSocket)**: Persistent connection — used by the VS Code extension for streaming (screenshots, logs, network events) and interactive commands

Both protocols speak the same MCP tool interface. The WebSocket adds push subscriptions (`logs`, `network`, `screenshots`) and binary screenshot frames for performance.
