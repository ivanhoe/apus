# Architecture

```text
Sources/Apus/
|-- Apus.swift                    # Public API (start, stop, register, log, action)
|-- Configuration.swift           # ApusConfiguration
|-- SwiftUISupport.swift          # @Inspectable, @ObserveInjection, .enableInjection(), .apusInspectable()
|-- Server/
|   |-- HTTPServer.swift          # Swifter wrapper, localhost:9847
|   |-- MCPProtocolHandler.swift  # JSON-RPC 2.0 routing
|   |-- MCPMessages.swift         # Protocol constants
|   `-- SecurityMiddleware.swift  # IP + origin validation
|-- Tools/
|   |-- MCPTool.swift             # Tool protocol
|   |-- ToolRegistry.swift        # Registration + dispatch
|   |-- LogCapture.swift          # Circular buffer log capture
|   |-- NetworkInterceptor.swift  # URLProtocol-based capture
|   |-- CoreDataInspector.swift   # NSFetchRequest builder
|   |-- SwiftDataInspector.swift  # ModelContainer schema reader
|   |-- ViewHierarchyInspector.swift  # UIWindow tree walker
|   |-- UserDefaultsReader.swift  # UserDefaults dump
|   |-- KeychainReader.swift      # SecItemCopyMatching queries
|   |-- FileBrowser.swift         # Sandbox file listing + reading
|   |-- ObjectInspector.swift     # Mirror-based reflection
|   |-- MemoryInspector.swift     # task_info + malloc stats
|   |-- ActionRunner.swift        # Developer-registered closures
|   |-- BuiltInActions.swift      # Built-in actions (cache, defaults, files, UI)
|   |-- AppInfoInspector.swift    # Bundle, plist, frameworks, environment
|   |-- ClassInspector.swift      # ObjC runtime class enumeration
|   |-- DiagnosticsTool.swift     # One-call app health summary
|   |-- HotReloadTool.swift       # Compile + inject Swift source via dylib (DEBUG)
|   |-- ProjectFileTools.swift    # Read/edit project source files (project-root scoped)
|   `-- ScreenshotCapture.swift   # UIWindow screenshot (iOS)
|-- CHotReload/
|   |-- fishhook.c / .h           # GOT entry patching
|   |-- interpose.c               # Symbol interposition helpers
|   `-- popen_wrapper.c           # C bridge for popen() in iOS builds
`-- Utilities/
    |-- CircularBuffer.swift      # Thread-safe ring buffer (logs, network)
    |-- OSLogReader.swift         # OSLogStore polling
    |-- StderrCapture.swift       # stdout/stderr interception
    |-- MirrorHelper.swift        # Reflection helpers
    `-- JSONHelper.swift          # Serialization
```
