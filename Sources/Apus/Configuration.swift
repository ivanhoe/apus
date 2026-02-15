import Foundation

/// Configuration for the Apus MCP server.
public struct ApusConfiguration {
    /// HTTP server port (default: 9847)
    public var port: UInt16

    /// Address to bind to (default: 127.0.0.1 for localhost-only)
    public var bindAddress: String

    /// Whether to automatically intercept URLSession network traffic
    public var interceptNetwork: Bool

    /// If set, only these tools will be registered (by name)
    public var enabledTools: Set<String>?

    /// Tools to exclude from registration (by name)
    public var disabledTools: Set<String>

    /// Disable automatic system log capture (OSLog + stderr).
    /// When true, only manual Apus.log() entries will appear in get_logs.
    public var disableSystemLogCapture: Bool

    public init(
        port: UInt16 = 9847,
        bindAddress: String = "127.0.0.1",
        interceptNetwork: Bool = false,
        enabledTools: Set<String>? = nil,
        disabledTools: Set<String> = [],
        disableSystemLogCapture: Bool = false
    ) {
        self.port = port
        self.bindAddress = bindAddress
        self.interceptNetwork = interceptNetwork
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.disableSystemLogCapture = disableSystemLogCapture
    }
}
