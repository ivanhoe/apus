# Runtime Workflows

Common setup patterns and prompts for day-to-day debugging.

## CoreData

```swift
#if DEBUG
Apus.shared.start(
    coreDataContext: persistenceController.container.viewContext
)
#endif
```

Prompt example:

> "Show me all User records where lastLogin is older than 7 days"

## Network Monitoring

```swift
#if DEBUG
Apus.shared.start(interceptNetwork: true)
#endif
```

Prompt example:

> "What API calls failed in the last minute?"

If you use custom URL sessions, use `Apus.shared.monitoredURLSession`.

## Object Inspection

```swift
#if DEBUG
Apus.shared.register(viewModel, id: "loginVM")
Apus.shared.register(appState, id: "appState")
#endif
```

Prompt example:

> "What's the current state of the login view model?"

## SwiftUI Helpers

Property wrapper:

```swift
struct ProfileView: View {
    @Inspectable("profileVM") var viewModel = ProfileViewModel()

    var body: some View {
        Text(viewModel.name)
    }
}
```

View modifier:

```swift
ContentView()
    .apusInspectable(appState, id: "appState")
```

## Actions (App-specific operations)

```swift
#if DEBUG
Apus.shared
    .action("clear_cache", description: "Clear URL and image caches") {
        URLCache.shared.removeAllCachedResponses()
        ImageCache.shared.clear()
        return "Cache cleared"
    }
    .action("reset_onboarding", description: "Reset onboarding so it shows again") {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    }
    .action("force_logout", description: "Clear auth tokens and force logout") {
        AuthManager.shared.clearTokens()
        return "Logged out - restart the app"
    }
#endif
```

Prompt example:

> "Clear the cache and check if the images load correctly now"

### Built-in actions (zero code)

Available as soon as you call `Apus.shared.start()`:

- `clear_url_cache`
- `clear_cookies`
- `clear_tmp`
- `set_user_default`
- `delete_user_default`
- `clear_all_user_defaults`
- `delete_file`
- `write_file`
- `open_url`
- `set_appearance`

Prompt examples:

> "Switch the app to dark mode"
> "Set UserDefaults key 'app.theme' to 'blue'"
> "Clear all cookies and the URL cache"

## Hot Reload (Simulator)

Compile Swift source and inject into the running app without restart.

Setup target flags:

```text
OTHER_LDFLAGS = $(inherited) -Xlinker -interposable
ENABLE_DEBUG_DYLIB = NO
```

Mark SwiftUI views for injection:

```swift
import Apus

struct MyView: View {
    @ObserveInjection var forceReload

    var body: some View {
        Text("Hello!")
            .enableInjection()
    }
}
```

Typical flow:

1. `read_project_file`
2. `edit_project_file`
3. `hot_reload(source_code:)`

Limitations:

- Simulator only
- Only self-contained structs
- dylib module name must match the app module name

## Logs and Diagnostics

Automatic capture is enabled by default:

- `os_log` / `Logger` via OSLogStore polling
- `print()` / `NSLog()` via stdout/stderr interception

Disable if needed:

```swift
Apus.shared.start(captureSystemLogs: false)
// or
Apus.shared.start(configuration: ApusConfiguration(disableSystemLogCapture: true))
```

Manual structured logs:

```swift
Apus.shared.log("Token refresh failed: 401", level: "error", source: "AuthService")
Apus.shared.log("Cart updated: 3 items", level: "info", source: "CartManager")
```

Useful prompts:

> "Show me all error logs from AuthService"
> "How much memory is the app using? Is there a leak?"
