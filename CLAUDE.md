# CLAUDE.md — Apus

## What is Apus?

Runtime MCP server embedded in iOS/macOS apps during development. AI agents inspect live state (logs, network, UI hierarchy, storage) without leaving the editor. Swift Package, zero dependencies.

## Architecture

```
Sources/
├── Apus/
│   ├── Apus.swift              # Entry point, singleton
│   ├── Configuration.swift     # Runtime config
│   ├── SwiftUISupport.swift    # SwiftUI integration
│   ├── Server/
│   │   ├── HTTPServer.swift         # Lightweight HTTP server (port 9847)
│   │   ├── MCPProtocolHandler.swift # JSON-RPC MCP handler
│   │   ├── MCPMessages.swift        # MCP message types
│   │   └── SecurityMiddleware.swift # Request validation
│   ├── Tools/                  # MCP tools (each = one capability)
│   │   ├── MCPTool.swift       # Protocol all tools conform to
│   │   ├── ToolRegistry.swift  # Discovery & dispatch
│   │   └── ...                 # ~20 tool implementations
│   └── Utilities/              # Helpers (circular buffer, JSON, mirror, logs)
├── CHotReload/                 # C bridging for hot reload (dylib injection)
└── Demo/                       # CLI demo target
ExampleApp/                     # SwiftUI example app
Tests/ApusTests/                # Unit tests (~25 test files)
```

## Tech Stack

- **Swift 5.9+**, iOS 16+ / macOS 13+
- **Swift Package Manager** (no CocoaPods/Carthage)
- **Zero external dependencies** — keep it that way
- MCP over HTTP (JSON-RPC 2.0) on `localhost:9847`
- Hot reload via runtime dylib injection (CHotReload C target)

## Conventions

### Swift Style
- Use Swift concurrency (`async/await`, actors) where appropriate
- Prefer value types (`struct`, `enum`) over classes unless reference semantics needed
- All public API must have doc comments
- `@MainActor` for anything touching UI
- `Sendable` conformance on types crossing concurrency boundaries
- No force unwraps (`!`) in library code — use `guard` or optional chaining
- No `print()` in library code — use `LogCapture` or `os_log`

### Code Organization
- One MCP tool per file in `Sources/Apus/Tools/`
- Every tool conforms to `MCPTool` protocol
- Register new tools in `ToolRegistry`
- Keep `Apus.swift` thin — delegate to subsystems
- Utilities are generic helpers, not tool-specific logic

### Testing
- Every tool should have a corresponding test file in `Tests/ApusTests/`
- Run tests: `swift test`
- Build check: `swift build`
- Test naming: `test<Feature>_<scenario>_<expected>()`

### Safety
- **Debug-only**: Apus must never run in release builds. Guard with `#if DEBUG`
- **Localhost-only**: HTTP server binds to `127.0.0.1`, never `0.0.0.0`
- **No secrets in responses**: Keychain reader shows metadata, not values
- **SecurityMiddleware**: All requests pass through validation

## Common Tasks

### Add a new MCP tool
1. Create `Sources/Apus/Tools/YourTool.swift`
2. Conform to `MCPTool` protocol
3. Register in `ToolRegistry.swift`
4. Add tests in `Tests/ApusTests/YourToolTests.swift`
5. Document in `docs/reference/tools.md`

### Build & Test
```bash
swift build                    # Compile
swift test                     # Run tests
swift package clean            # Clean build artifacts
```

### Run ExampleApp
Build via Xcode (`ExampleApp` scheme) → run on simulator → verify `http://localhost:9847/` responds.

## Code Review Checklist

When reviewing or writing code for Apus, verify:

### Correctness
- [ ] No retain cycles (watch for `self` in closures — use `[weak self]`)
- [ ] Proper `@Sendable` and `Sendable` usage across concurrency boundaries
- [ ] No data races — mutable state protected by actor or lock
- [ ] Error handling: no `try!` or `fatalError` in library code
- [ ] Optional handling: no force unwraps

### Performance
- [ ] No blocking the main thread (network, file I/O → background)
- [ ] CircularBuffer used for bounded collections (logs, network history)
- [ ] No unbounded memory growth in long-running inspectors

### Security
- [ ] New endpoints go through SecurityMiddleware
- [ ] No sensitive data (passwords, tokens) in tool responses
- [ ] Localhost binding preserved
- [ ] File access scoped to app sandbox

### API Design
- [ ] Public API has doc comments
- [ ] Tool JSON schema is well-defined (clear parameter names, descriptions)
- [ ] Backward compatible — don't break existing MCP tool contracts
- [ ] Response sizes are bounded (truncate large outputs)

### Testing
- [ ] New functionality has tests
- [ ] Edge cases covered (empty state, errors, large inputs)
- [ ] Tests are independent (no shared mutable state between tests)

## Session Memory (2026-02-25)

### ui_interact hardening (2026-02-24)
- `tap` returns error when no activation handler exists.
- `double_tap` fails unless both activations succeed.
- `long_press` errors when no gesture recognizer and no fallback.
- `swipe` handles UIScrollView targets directly via `contentOffset` fallback.
- Helpers exposed for testing: `activateView(_:) -> ActivationResult`, `firstScrollableView(startingAt:) -> UIScrollView?`
- iOS MCP tests in `ExampleApp/Tests/UIInteractionMCPTests.swift` (less flaky: retry + readiness polling).
- CI job `ios-uikit-tests` added in `.github/workflows/ci.yml`.

### Interactive Live Preview — VS Code Extension (2026-02-25)
- **File modified**: `vscode-extension/src/panels/live-preview-panel.ts`
- **What it does**: screenshot webview now interactive — click/drag/type sobre la imagen → `ui_interact` MCP call → cambio real en la app
- **Flujo**: webview events → `postMessage` → extension host `onDidReceiveMessage` → `client.callTool("ui_interact", args)` → toast con respuesta
- **Coordinate math**: device_point = JPEG_pixel / scale. Letterbox handling (object-fit contain) calcula el área rendered real dentro del img element.
- **Gestures**: tap (300ms delay), double-tap, swipe (por vector), keyboard (debounce 150ms → type_text)
- **Visual**: ripple azul/naranja, swipe line, toast inferior, kbd indicator superior-derecho
- **PENDING**: reemplazar coordenadas crudas con view hierarchy hit-testing → enviar `identifier`/`label`/`path` en vez de `coordinate`

### Current known failures
- `swift test` falla en `JSONHelperTests` (2 tests pre-existentes, no relacionados):
  - `testSerialize_emptyDictionary_returnsEmptyObject` (`Tests/ApusTests/JSONHelperTests.swift:89`)
  - `testSerialize_emptyArray_returnsEmptyArray` (`Tests/ApusTests/JSONHelperTests.swift:96`)

## Don'ts
- Don't add external dependencies — Apus is zero-dep by design
- Don't expose Apus API in release builds
- Don't use SwiftUI previews for tool logic testing — use unit tests
- Don't put tool-specific logic in Utilities/
- Don't break the MCP JSON-RPC contract (clients depend on stable schemas)
