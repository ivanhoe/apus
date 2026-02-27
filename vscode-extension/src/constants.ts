/** Default WebSocket port matching Apus server (WebSocketServer.swift). */
export const DEFAULT_WS_PORT = 9848;

/** Default WebSocket host — localhost only for security. */
export const DEFAULT_WS_HOST = "127.0.0.1";

/** Subscription channel names matching SubscriptionManager.swift. */
export const CHANNELS = {
  LOGS: "logs",
  NETWORK: "network",
  SCREENSHOTS: "screenshots",
} as const;

/** Server notification method names matching EventBroadcaster.swift. */
export const NOTIFICATIONS = {
  LOG: "notifications/log",
  NETWORK: "notifications/network",
} as const;

/** Default reconnect interval in milliseconds. */
export const DEFAULT_RECONNECT_INTERVAL_MS = 5000;

/** Default screenshot settings matching ScreenshotStreamer.swift defaults. */
export const DEFAULT_SCREENSHOT_FPS = 5;
export const DEFAULT_SCREENSHOT_SCALE = 2;
export const DEFAULT_SCREENSHOT_QUALITY = 1;
export const DEFAULT_IDLE_SCREENSHOT_FPS = 1;
export const DEFAULT_INTERACTION_BOOST_MS = 2500;
export const DEFAULT_INTERACTION_STRICT_MODE = true;

/** Default log buffer size. */
export const DEFAULT_LOG_BUFFER_SIZE = 1000;

/** MCP protocol version. */
export const MCP_PROTOCOL_VERSION = "2024-11-05";
