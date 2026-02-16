import Foundation
import CoreData

/// Apus embeds an MCP server inside your iOS app (debug builds only)
/// that exposes runtime inspection tools to AI agents and editors.
///
/// Named after the swift — a bird that never lands.
///
/// ## Quick Start
/// ```swift
/// #if DEBUG
/// Apus.shared.start()
/// #endif
/// ```
///
/// ## With CoreData
/// ```swift
/// #if DEBUG
/// Apus.shared.start(
///     coreDataContext: persistenceController.container.viewContext
/// )
/// #endif
/// ```
public final class Apus {
    /// Shared singleton instance.
    public static let shared = Apus()

    private var server: MCPHTTPServer?
    private var protocolHandler: MCPProtocolHandler?
    private let toolRegistry = ToolRegistry()
    private let logCapture = LogCapture()
    private let objectInspector = ObjectInspector()
    private let actionRunner = ActionRunner()
    private var networkInterceptor: NetworkInterceptor?
    private var isRunning = false
    private(set) var projectRoot: String?

    private init() {}

    // MARK: - Public API

    /// Start the MCP server with the given configuration.
    ///
    /// - Parameters:
    ///   - port: HTTP server port (default: 9847)
    ///   - coreDataContext: Optional NSManagedObjectContext for CoreData inspection
    ///   - modelContainer: Optional SwiftData ModelContainer (pass as Any to avoid iOS 17+ requirement)
    ///   - interceptNetwork: Whether to automatically intercept URLSession traffic
    ///   - captureSystemLogs: Whether to capture os_log/Logger and print()/NSLog() output automatically (default: true)
    ///   - configuration: Additional configuration options
    public func start(
        port: UInt16 = 9847,
        coreDataContext: NSManagedObjectContext? = nil,
        modelContainer: Any? = nil,
        interceptNetwork: Bool = false,
        captureSystemLogs: Bool = true,
        configuration: ApusConfiguration = .init(),
        callerFilePath: String = #filePath
    ) {
        guard !isRunning else {
            print("[Apus] Already running on port \(configuration.port)")
            return
        }

        #if !DEBUG
        print("[Apus] WARNING: Running outside of DEBUG configuration. This is intended for development only.")
        #endif

        self.projectRoot = Self.detectProjectRoot(from: callerFilePath)

        let effectivePort = port != 9847 ? port : configuration.port
        let effectiveIntercept = interceptNetwork || configuration.interceptNetwork
        let effectiveCaptureLogs = captureSystemLogs && !configuration.disableSystemLogCapture

        // Register tools
        registerDefaultTools(
            coreDataContext: coreDataContext,
            modelContainer: modelContainer,
            interceptNetwork: effectiveIntercept,
            configuration: configuration
        )

        // Start system log capture (OSLog + stderr)
        if effectiveCaptureLogs {
            logCapture.startSystemCapture()
        }

        // Setup protocol handler
        let handler = MCPProtocolHandler(toolRegistry: toolRegistry)
        self.protocolHandler = handler

        // Setup and start HTTP server
        let security = SecurityMiddleware()
        let httpServer = MCPHTTPServer(handler: handler, security: security)
        self.server = httpServer

        do {
            try httpServer.start(port: effectivePort, bindAddress: configuration.bindAddress)
            isRunning = true
            print("[Apus] MCP server started on http://\(configuration.bindAddress):\(effectivePort)/mcp")
            print("[Apus] \(toolRegistry.toolCount) tools registered")
            print("[Apus] Configure your editor:")
            print("[Apus]   { \"mcpServers\": { \"ios-runtime\": { \"url\": \"http://localhost:\(effectivePort)/mcp\" } } }")
        } catch {
            print("[Apus] Failed to start server: \(error)")
        }
    }

    /// Stop the MCP server.
    public func stop() {
        logCapture.stopSystemCapture()
        server?.stop()
        server = nil
        protocolHandler = nil
        isRunning = false
        print("[Apus] Server stopped")
    }

    /// Register an object for inspection via the `inspect_object` tool.
    ///
    /// For reference types (classes), a weak reference is stored.
    /// For value types (structs), a copy is stored — re-register to update.
    ///
    /// - Parameters:
    ///   - object: The object to register
    ///   - id: A unique identifier for this object
    public func register(_ object: Any, id: String) {
        objectInspector.register(object, id: id)
    }

    /// Register a provider closure for dynamic object inspection.
    /// The closure is called each time the object is inspected, returning the current value.
    ///
    /// - Parameters:
    ///   - id: A unique identifier
    ///   - provider: A closure returning the current object value
    public func register(id: String, provider: @escaping () -> Any?) {
        objectInspector.register(id: id, provider: provider)
    }

    /// Unregister an object by its ID.
    public func unregister(id: String) {
        objectInspector.unregister(id: id)
    }

    /// Log a message that will be captured by the `get_logs` tool.
    ///
    /// - Parameters:
    ///   - message: The log message
    ///   - level: Log level: "debug", "info", "warning", "error" (default: "info")
    ///   - source: Source identifier (default: "app")
    public func log(_ message: String, level: String = "info", source: String = "app") {
        logCapture.log(message, level: level, source: source)
    }

    /// Returns a URLSession configured to record network traffic.
    /// Use this session for requests you want to inspect via `get_network_history`.
    public var monitoredURLSession: URLSession {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [ApusURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Actions

    /// Register an action that the AI agent can execute.
    ///
    /// Actions are the Swift equivalent of "eval" — you define what the agent
    /// is allowed to do, and it can discover and invoke these actions by name.
    ///
    /// ```swift
    /// Apus.shared.action("clear_cache", description: "Clear all caches") {
    ///     URLCache.shared.removeAllCachedResponses()
    ///     return "Cache cleared (\(URLCache.shared.currentDiskUsage) bytes on disk)"
    /// }
    ///
    /// Apus.shared.action("reset_onboarding") {
    ///     UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: Unique action name (snake_case recommended)
    ///   - description: What this action does (shown to the AI agent)
    ///   - handler: The closure to execute. Return a String for custom output, or nil for default "success" message.
    @discardableResult
    public func action(
        _ name: String,
        description: String = "",
        handler: @escaping () async throws -> String?
    ) -> Self {
        actionRunner.register(
            name: name,
            description: description.isEmpty ? "Execute \(name)" : description,
            handler: handler
        )
        return self
    }

    /// Register a synchronous action (convenience for closures that don't need async).
    @discardableResult
    public func action(
        _ name: String,
        description: String = "",
        handler: @escaping () throws -> String?
    ) -> Self {
        actionRunner.register(
            name: name,
            description: description.isEmpty ? "Execute \(name)" : description,
            handler: { try handler() }
        )
        return self
    }

    /// Register a fire-and-forget action (no return value needed).
    @discardableResult
    public func action(
        _ name: String,
        description: String = "",
        perform: @escaping () throws -> Void
    ) -> Self {
        actionRunner.register(
            name: name,
            description: description.isEmpty ? "Execute \(name)" : description,
            handler: { try perform(); return nil }
        )
        return self
    }

    /// Remove a registered action.
    public func removeAction(_ name: String) {
        actionRunner.unregister(name: name)
    }

    /// Whether the MCP server is currently running.
    public var running: Bool { isRunning }

    // MARK: - Project Root Detection

    private static func detectProjectRoot(from filePath: String) -> String? {
        var url = URL(fileURLWithPath: filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.contains(where: { $0.hasSuffix(".xcodeproj") || $0 == "Package.swift" }) {
                return url.path
            }
        }
        return nil
    }

    // MARK: - Tool Registration

    private func registerDefaultTools(
        coreDataContext: NSManagedObjectContext?,
        modelContainer: Any?,
        interceptNetwork: Bool,
        configuration: ApusConfiguration
    ) {
        let security = SecurityMiddleware()

        // Always-available tools
        toolRegistry.register(logCapture)
        toolRegistry.register(UserDefaultsReader())
        toolRegistry.register(FileBrowser(security: security))
        toolRegistry.register(FileReader(security: security))
        toolRegistry.register(objectInspector)
        toolRegistry.register(actionRunner)
        BuiltInActions.register(on: actionRunner)
        toolRegistry.register(KeychainReader())
        toolRegistry.register(MemoryInspector())
        toolRegistry.register(AppInfoInspector())
        toolRegistry.register(ClassInspector())

        #if DEBUG
        toolRegistry.register(HotReloadTool())
        #endif

        // UIKit tools (iOS only)
        #if canImport(UIKit) && !os(watchOS)
        toolRegistry.register(ViewHierarchyInspector())
        toolRegistry.register(ScreenshotCapture())
        #endif

        // CoreData tools
        if let context = coreDataContext {
            toolRegistry.register(CoreDataInspector(context: context))
            toolRegistry.register(ExecuteFetchRequest(context: context))
        }

        // SwiftData tools
        if let container = modelContainer {
            if #available(iOS 17, macOS 14, *) {
                toolRegistry.register(SwiftDataInspector(container: container))
            }
        }

        // Network interceptor
        if interceptNetwork {
            let interceptor = NetworkInterceptor()
            self.networkInterceptor = interceptor
            ApusURLProtocol.interceptor = interceptor
            URLProtocol.registerClass(ApusURLProtocol.self)
            toolRegistry.register(interceptor)
        }

        // Project source file tools (require projectRoot detection)
        if let projectRoot = self.projectRoot {
            toolRegistry.register(ProjectFileReader(projectRoot: projectRoot, security: security))
            toolRegistry.register(ProjectFileEditor(projectRoot: projectRoot, security: security))
        }

        // Diagnostics meta-tool (aggregates data from other tools)
        toolRegistry.register(DiagnosticsTool(
            logCapture: logCapture,
            networkInterceptor: networkInterceptor,
            actionRunner: actionRunner,
            toolRegistry: toolRegistry
        ))

        // Apply enabled tools allowlist (if provided)
        if let enabledTools = configuration.enabledTools {
            let registeredNames = toolRegistry
                .toolsList()
                .compactMap { $0["name"] as? String }
            for name in registeredNames where !enabledTools.contains(name) {
                toolRegistry.unregister(name: name)
            }
        }

        // Remove disabled tools
        for name in configuration.disabledTools {
            toolRegistry.unregister(name: name)
        }
    }
}
