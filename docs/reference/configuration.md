# Configuration

## Basic Start

```swift
#if DEBUG
Apus.shared.start()
#endif
```

## Common Options

```swift
#if DEBUG
Apus.shared.start(
    port: 9847,
    coreDataContext: container.viewContext,
    interceptNetwork: true,
    captureSystemLogs: true,
    configuration: ApusConfiguration(
        bindAddress: "127.0.0.1",
        enabledTools: ["get_logs", "get_screenshot"],
        disabledTools: ["get_keychain_items"],
        disableSystemLogCapture: false
    )
)
#endif
```

## Parameters

| Parameter | Purpose |
|----------|---------|
| `port` | HTTP port for Apus MCP server (default `9847`) |
| `coreDataContext` | Enables CoreData tools |
| `interceptNetwork` | Enables URL request/response history |
| `captureSystemLogs` | Enables automatic log capture (`true` by default) |
| `configuration.bindAddress` | Network interface bind address (default localhost-only) |
| `configuration.enabledTools` | Optional allow-list of tool IDs |
| `configuration.disabledTools` | Optional deny-list of tool IDs |
| `configuration.disableSystemLogCapture` | Disable OSLog/stdout interception via configuration |

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [Swifter](https://github.com/httpswift/swifter) | Embedded HTTP server |

## Platform Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+
