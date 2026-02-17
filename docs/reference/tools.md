# Tools Catalog

Tool availability depends on platform and your `start(...)` configuration.

## Always Available (Default)

| Tool | Description |
|------|-------------|
| `get_diagnostics` | One-call health summary (app info, memory, errors, network, config). Start here. |
| `get_logs` | Recent app logs with filtering by level, keyword, and count |
| `get_memory_stats` | Physical footprint, peak memory, heap stats, available system memory |
| `execute_action` | Run developer-registered actions (clear cache, reset state, etc.) |
| `get_app_info` | Bundle ID, version, build config, loaded frameworks, environment |
| `list_classes` | Enumerate ObjC runtime classes, inspect properties and methods |
| `get_user_defaults` | All UserDefaults key-value pairs, filterable by prefix |
| `browse_files` | List files in the app sandbox with sizes and dates |
| `read_file` | Read file contents (text or base64 for binary) |
| `inspect_object` | Inspect registered objects via Swift Mirror reflection |
| `get_keychain_items` | List keychain items (metadata only, secrets redacted) |

## Project Source Files (Auto-detected)

Available when Apus detects a project root (`.xcodeproj` or `Package.swift`):

| Tool | Description |
|------|-------------|
| `read_project_file` | Read source files relative to project root, with line numbers and optional line range |
| `edit_project_file` | Find-and-replace in source files (rejects ambiguous matches with >1 occurrence) |

## Debug-only (Simulator-focused)

| Tool | Description |
|------|-------------|
| `hot_reload` | Compile Swift source and inject into the running app. Returns screenshot of result. |

## iOS Only

| Tool | Description |
|------|-------------|
| `get_screenshot` | Capture a PNG screenshot of the current screen |
| `get_view_hierarchy` | UIKit view tree with types, frames, accessibility info |

## With CoreData

| Tool | Description |
|------|-------------|
| `inspect_core_data` | Browse entities and fetch records with NSPredicate filtering |
| `execute_fetch_request` | Full-control fetch requests (read-only) |

## With SwiftData (iOS 17+)

| Tool | Description |
|------|-------------|
| `inspect_swift_data` | Inspect model schemas, attributes, and relationships |

## With Network Interception

Requires `start(interceptNetwork: true)`.

| Tool | Description |
|------|-------------|
| `get_network_history` | Request/response history with headers, bodies, status codes, and timing |
