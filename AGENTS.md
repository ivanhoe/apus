# AGENTS.md — Apus Working Memory

Last updated: 2026-02-26

## What is Apus

Runtime MCP server embedded in iOS/macOS apps during development. Exposes debugging tools over `localhost:9847` (HTTP/JSON-RPC) and `localhost:9848` (WebSocket). Zero external dependencies — Swift Package.

## Build & Test

```bash
swift build                    # Compile Swift package
swift test                     # Run all tests (~382 tests, 2 pre-existing failures in JSONHelperTests)
cd vscode-extension && npm run build   # Build VS Code extension
```

## Current Branch: `feature/ui-interaction-tool` → PR #9 → main

### What's in this branch
1. **`ui_interact` MCP tool** — `Sources/Apus/Tools/UIInteractionTool.swift`
   - Actions: `tap`, `double_tap`, `long_press`, `swipe`, `type_text`
   - Targeting priority: `identifier` > `label` > `path` > `coordinate: {x, y}`
   - `swipe` handles UIScrollView targets directly via `contentOffset` fallback
   - `activateView(_:) -> ActivationResult` and `firstScrollableView(startingAt:)` exposed for testing

2. **iOS MCP integration tests** — `ExampleApp/Tests/UIInteractionMCPTests.swift`
   - Uses retry + readiness polling (not fixed sleep) for server startup
   - CI job: `ios-uikit-tests` in `.github/workflows/ci.yml`

3. **Interactive Live Preview** — `vscode-extension/src/panels/live-preview-panel.ts`
   - Click/drag/type on the screenshot → `ui_interact` MCP call → action in the real app
   - Coordinate math: `device_point = JPEG_pixel / scale` with object-fit contain letterbox handling
   - Gestures: tap (300ms double-tap window), double-tap, swipe (direction from vector), keyboard (150ms debounce)
   - Visual: ripple animations, swipe line, toast bar, keyboard indicator
   - Strict semantic targeting mode (`apus.interactionStrictMode`, default `true`): blocks coordinate fallback when identifier/label cannot be resolved

4. **Inspector 3D-first mode** — `vscode-extension/src/panels/inspector-panel.ts` + `vscode-extension/src/webviews/inspector-panel.ts`
   - Inspector now defaults to a 3D hierarchy viewport (Three.js + OrbitControls) with camera controls (`Fit`, `Focus`, `Top`, `Front`, `Refresh 3D`)
   - Webview requests `get_view_hierarchy` snapshots from host (`requestHierarchy`) and rebuilds layered planes from view frames
   - Touch interaction remains available as secondary mode (`Touch`) instead of primary default

5. **Hierarchy reliability hardening**
   - `get_view_hierarchy` excluded from ToolRegistry response cache marker path (server no longer returns `"(unchanged since last call)"` for hierarchy in updated runtime)
   - Inspector + interaction resolver now handle unchanged marker defensively and reuse last good hierarchy snapshot
   - Added forced refresh fallback with `cache_bust` when first hierarchy fetch has no usable prior snapshot
   - Added retry with backoff and progressive depth probing for hierarchy (`8 -> 12 -> 16`)
   - Added per-call MCP timeout support in `ApusClient.callTool(name, args, { timeoutMs })`
   - Increased timeout for heavy calls:
     - `get_view_hierarchy`: 25s
     - `ui_interact`: 15s (Inspector + Live Preview)

6. **Inspector layout resizing UX**
   - Desktop: new vertical splitter between preview and Logs/Network side panel (draggable width)
   - Stacked/small layout: top handle for Logs/Network panel height (draggable)
   - Keeps responsive behavior and minimum pane sizes

## Known Issues / Pending

- **Live Preview targeting (resolved)**: Coordinate-only mode was replaced with `get_view_hierarchy` hit-testing. In strict mode, coordinate fallback is blocked unless disabled in settings.
- **Inspector Execute UX**: Record/run flows are implemented in-webview; next iteration can add persistent script storage + step editing.
- **Inspector perf hotspots (current)**:
  - `inspector-panel.js` bundle is large (~1.2 MB uncompressed; ~216 KB gzip)
  - 3D scene render loop runs continuously with `requestAnimationFrame`
  - JPEG -> `Image` -> new `THREE.Texture` churn per screenshot update
  - Event list status computes visible rows using DOM query scans (`querySelectorAll`) on updates
- **JSONHelperTests**: 2 pre-existing failures (`testSerialize_emptyArray`, `testSerialize_emptyDictionary`) — unrelated to this work.
- **iOS simulator tests**: Can't run locally (CoreSimulator restrictions). Expected to run in GitHub Actions macOS runners.

## Key Files

| File | Purpose |
|------|---------|
| `Sources/Apus/Tools/UIInteractionTool.swift` | ui_interact MCP tool |
| `Tests/ApusTests/UIInteractionToolTests.swift` | 28 unit tests (iOS only, `#if canImport(UIKit)`) |
| `ExampleApp/Tests/UIInteractionMCPTests.swift` | iOS end-to-end MCP tests |
| `vscode-extension/src/panels/live-preview-panel.ts` | Interactive Live Preview webview |
| `vscode-extension/src/apus-client.ts` | `callTool(name, args)` — calls any MCP tool |
| `.github/workflows/ci.yml` | CI including `ios-uikit-tests` job |
| `ExampleApp/scripts/patch-local-package-reference.sh` | Patches xcodegen output for local SPM wiring |
| `Sources/Apus/Tools/ToolRegistry.swift` | Tool response caching and unchanged marker behavior |
| `vscode-extension/src/panels/interaction-target-resolver.ts` | Hierarchy fetch/retry + semantic targeting resolver |
| `vscode-extension/src/webviews/inspector-panel.ts` | Inspector webview runtime (3D scene, events UI, splitters) |

## Architecture Notes

- MCP tool response format: `{ content: [{ type: "text", text: "..." }] }`
- `callTool(name, args, options?)` in ApusClient returns `Promise<unknown>` (the raw result)
- `options.timeoutMs` supports per-call timeout overrides for slow tools
- WebSocket port 9848 is separate from HTTP 9847 — NWProtocolWebSocket requires all connections be WS
- Screenshot frames: binary `[4-byte seq LE][JPEG data]` over WebSocket
- Stream defaults: scale 2.0, JPEG quality 1.0 (JPEG pixels = device points × scale)

## Collaboration Preferences (User)

1. Prefer plan-first workflow before substantial actions.
2. Prefer numbered responses.
3. In chat responses, avoid printing file paths; mention filenames only.
