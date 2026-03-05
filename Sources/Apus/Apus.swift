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

    private var _server: MCPHTTPServer?
    private var _protocolHandler: MCPProtocolHandler?
    private let toolRegistry = ToolRegistry()
    private let logCapture = LogCapture()
    private let objectInspector = ObjectInspector()
    private let actionRunner = ActionRunner()
    private var _networkInterceptor: NetworkInterceptor?
    private var _isRunning = false
    private var _projectRoot: String?
    private let stateLock = NSLock()

    /// The detected project root directory (thread-safe).
    var projectRoot: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _projectRoot
    }

    // WebSocket subsystem
    private var wsServer: WebSocketServer?
    private var subscriptionManager: SubscriptionManager?
    private var eventBroadcaster: EventBroadcaster?
    #if canImport(UIKit) && !os(watchOS)
    private var screenshotStreamer: ScreenshotStreamer?
    #endif
    private var diagnosticsTool: DiagnosticsTool?

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
        stateLock.lock()
        guard !_isRunning else {
            stateLock.unlock()
            print("[Apus] Already running on port \(configuration.port)")
            return
        }
        stateLock.unlock()

        #if !DEBUG
        print("[Apus] WARNING: Running outside of DEBUG configuration. This is intended for development only.")
        #endif

        let detectedRoot = Self.detectProjectRoot(from: callerFilePath)
        stateLock.lock()
        self._projectRoot = detectedRoot
        stateLock.unlock()

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

        // Setup and start HTTP server
        let security = SecurityMiddleware()
        let httpServer = MCPHTTPServer(handler: handler, security: security)

        stateLock.lock()
        self._protocolHandler = handler
        self._server = httpServer
        stateLock.unlock()

        var didStartHTTP = false
        do {
            try httpServer.start(port: effectivePort, bindAddress: configuration.bindAddress)
            stateLock.lock()
            _isRunning = true
            stateLock.unlock()
            didStartHTTP = true
            print("[Apus] MCP server started on http://\(configuration.bindAddress):\(effectivePort)/mcp")
            print("[Apus] \(toolRegistry.toolCount) tools registered")
            print("[Apus] Configure your editor:")
            print("[Apus]   { \"mcpServers\": { \"ios-runtime\": { \"url\": \"http://localhost:\(effectivePort)/mcp\" } } }")
        } catch {
            stateLock.lock()
            _server = nil
            _protocolHandler = nil
            stateLock.unlock()
            print("[Apus] Failed to start server: \(error)")
        }

        // WebSocket server (persistent bidirectional channel)
        if didStartHTTP && configuration.enableWebSocket {
            startWebSocketServer(
                handler: handler,
                bindAddress: configuration.bindAddress,
                wsPort: configuration.wsPort
            )
        }
    }

    // MARK: - WebSocket Setup

    private func startWebSocketServer(
        handler: MCPProtocolHandler,
        bindAddress: String,
        wsPort: UInt16
    ) {
        let subManager = SubscriptionManager()
        self.subscriptionManager = subManager

        let ws = WebSocketServer(handler: handler)
        ws.subscriptionManager = subManager
        self.wsServer = ws

        // Event broadcaster bridges log/network events → WS notifications
        let broadcaster = EventBroadcaster(
            connectionManager: ws.connectionManager,
            subscriptionManager: subManager
        )
        self.eventBroadcaster = broadcaster

        // Wire log push
        logCapture.onNewEntry = { [weak broadcaster] entry in
            broadcaster?.broadcastLogEntry(entry)
        }

        // Wire network push
        _networkInterceptor?.onNewRecord = { [weak broadcaster] record in
            broadcaster?.broadcastNetworkRecord(record)
        }

        // Wire diagnostics
        diagnosticsTool?.wsConnectionManager = ws.connectionManager
        diagnosticsTool?.wsSubscriptionManager = subManager

        // Screenshot streaming: start/stop based on subscription changes
        #if canImport(UIKit) && !os(watchOS)
        let streamer = ScreenshotStreamer(broadcaster: broadcaster, subscriptionManager: subManager)
        self.screenshotStreamer = streamer

        subManager.onSubscriptionChange = { [weak streamer, weak subManager] channel, count in
            guard channel == EventBroadcaster.screenshotsChannel else { return }
            guard let streamer else { return }
            if count > 0 {
                let config = Self.resolveScreenshotStreamConfig(from: subManager)
                streamer.start(fps: config.fps, scale: config.scale, quality: config.quality)
            } else if count == 0 {
                streamer.stop()
            }
        }
        #endif

        do {
            try ws.start(port: wsPort, bindAddress: bindAddress)
            handler.wsPort = wsPort
            print("[Apus] WebSocket server started on ws://\(bindAddress):\(wsPort)")
        } catch {
            logCapture.onNewEntry = nil
            _networkInterceptor?.onNewRecord = nil
            diagnosticsTool?.wsConnectionManager = nil
            diagnosticsTool?.wsSubscriptionManager = nil
            self.wsServer = nil
            self.subscriptionManager = nil
            self.eventBroadcaster = nil
            #if canImport(UIKit) && !os(watchOS)
            screenshotStreamer?.stop()
            screenshotStreamer = nil
            #endif
            print("[Apus] Failed to start WebSocket server: \(error)")
        }
    }

    /// Stop the MCP server.
    public func stop() {
        #if canImport(UIKit) && !os(watchOS)
        screenshotStreamer?.stop()
        screenshotStreamer = nil
        #endif
        logCapture.onNewEntry = nil
        _networkInterceptor?.onNewRecord = nil
        wsServer?.stop()
        wsServer = nil
        subscriptionManager = nil
        eventBroadcaster = nil
        diagnosticsTool?.wsConnectionManager = nil
        diagnosticsTool?.wsSubscriptionManager = nil
        diagnosticsTool = nil
        logCapture.stopSystemCapture()

        stateLock.lock()
        let serverRef = _server
        _server = nil
        _protocolHandler = nil
        _networkInterceptor = nil
        _isRunning = false
        stateLock.unlock()

        serverRef?.stop()
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

    #if canImport(UIKit) && !os(watchOS)
    private struct ScreenshotStreamConfig {
        let fps: Double
        let scale: CGFloat
        let quality: CGFloat
    }

    private static func resolveScreenshotStreamConfig(from subManager: SubscriptionManager?) -> ScreenshotStreamConfig {
        guard let subManager else {
            return ScreenshotStreamConfig(
                fps: ScreenshotStreamer.defaultFPS,
                scale: ScreenshotStreamer.defaultScale,
                quality: ScreenshotStreamer.defaultQuality
            )
        }

        let channel = EventBroadcaster.screenshotsChannel
        let subscribers = subManager.subscribers(for: channel)

        var requestedFPS: Double?
        var requestedScale: Double?
        var requestedQuality: Double?

        for connectionId in subscribers {
            guard let options = subManager.options(for: connectionId, channel: channel) else { continue }

            if let fps = readOptionNumber(options["fps"]) {
                requestedFPS = max(requestedFPS ?? fps, fps)
            }
            if let scale = readOptionNumber(options["scale"]) {
                requestedScale = max(requestedScale ?? scale, scale)
            }
            if let quality = readOptionNumber(options["quality"]) {
                requestedQuality = max(requestedQuality ?? quality, quality)
            }
        }

        let fps = min(max(requestedFPS ?? ScreenshotStreamer.defaultFPS, 1), ScreenshotStreamer.maxFPS)
        let scale = min(max(requestedScale ?? Double(ScreenshotStreamer.defaultScale), 0.01), 2.0)
        let quality = min(max(requestedQuality ?? Double(ScreenshotStreamer.defaultQuality), 0.0), 1.0)

        return ScreenshotStreamConfig(
            fps: fps,
            scale: CGFloat(scale),
            quality: CGFloat(quality)
        )
    }

    private static func readOptionNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as Double:
            return number
        case let number as Float:
            return Double(number)
        case let number as Int:
            return Double(number)
        case let number as NSNumber:
            return number.doubleValue
        case let text as String:
            return Double(text)
        default:
            return nil
        }
    }
    #endif

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
    public var running: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRunning
    }

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
        toolRegistry.register(ViewHighlighter())
        toolRegistry.register(ViewPropertyEditor())
        toolRegistry.register(ViewSnapshotCapture())
        toolRegistry.register(UIInteractionTool())
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
            stateLock.lock()
            self._networkInterceptor = interceptor
            stateLock.unlock()
            ApusURLProtocol.interceptor = interceptor
            URLProtocol.registerClass(ApusURLProtocol.self)
            toolRegistry.register(interceptor)
            toolRegistry.register(NetworkRequestDetail(interceptor: interceptor))
        }

        // Project source file tools (require projectRoot detection)
        if let projectRoot = self.projectRoot {
            toolRegistry.register(ProjectFileReader(projectRoot: projectRoot, security: security))
            toolRegistry.register(ProjectFileEditor(projectRoot: projectRoot, security: security))
        }

        // Diagnostics meta-tool (aggregates data from other tools)
        let diagTool = DiagnosticsTool(
            logCapture: logCapture,
            networkInterceptor: _networkInterceptor,
            actionRunner: actionRunner,
            toolRegistry: toolRegistry
        )
        self.diagnosticsTool = diagTool
        toolRegistry.register(diagTool)

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
