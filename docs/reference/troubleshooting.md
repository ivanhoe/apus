# Troubleshooting

## Agent cannot connect to Apus

- Confirm the app is running in Debug and calls `Apus.shared.start(...)`.
- Open `http://localhost:9847/` and verify `Status: Running`.
- If you changed the port, update the MCP URL in your editor.

## `get_network_history` is empty

- Start Apus with `interceptNetwork: true`.
- If you use custom URL sessions, use `Apus.shared.monitoredURLSession`.

## Running on a physical iPhone

- Start with iOS Simulator for the fastest first setup.
- Default bind address is `127.0.0.1`, so host/editor access is local-only.

## Missing tools you expected

- `get_screenshot` and `get_view_hierarchy` are iOS-only.
- CoreData/SwiftData tools appear only when context/container is passed to `start(...)`.
- `hot_reload` is Debug-only and simulator-focused.
