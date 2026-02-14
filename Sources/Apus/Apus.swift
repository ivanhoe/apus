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
    private var networkInterceptor: NetworkInterceptor?
    private var isRunning = false

    private init() {}

    // MARK: - Public API

    /// Start the MCP server with the given configuration.
    ///
    /// - Parameters:
    ///   - port: HTTP server port (default: 9847)
    ///   - coreDataContext: Optional NSManagedObjectContext for CoreData inspection
    ///   - modelContainer: Optional SwiftData ModelContainer (pass as Any to avoid iOS 17+ requirement)
    ///   - interceptNetwork: Whether to automatically intercept URLSession traffic
    ///   - configuration: Additional configuration options
    public func start(
        port: UInt16 = 9847,
        coreDataContext: NSManagedObjectContext? = nil,
        modelContainer: Any? = nil,
        interceptNetwork: Bool = false,
        configuration: ApusConfiguration = .init()
    ) {
        guard !isRunning else {
            print("[Apus] Already running on port \(configuration.port)")
            return
        }

        #if !DEBUG
        print("[Apus] WARNING: Running outside of DEBUG configuration. This is intended for development only.")
        #endif

        let effectivePort = port != 9847 ? port : configuration.port
        let effectiveIntercept = interceptNetwork || configuration.interceptNetwork

        // Register tools
        registerDefaultTools(
            coreDataContext: coreDataContext,
            modelContainer: modelContainer,
            interceptNetwork: effectiveIntercept,
            configuration: configuration
        )

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

    /// Whether the MCP server is currently running.
    public var running: Bool { isRunning }

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
        toolRegistry.register(KeychainReader())

        // UIKit view hierarchy (iOS only)
        #if canImport(UIKit) && !os(watchOS)
        toolRegistry.register(ViewHierarchyInspector())
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

        // Remove disabled tools
        for name in configuration.disabledTools {
            toolRegistry.unregister(name: name)
        }
    }
}
