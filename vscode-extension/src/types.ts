/** WebSocket connection state. */
export type ConnectionState = "disconnected" | "connecting" | "connected";

/** MCP server info returned by initialize. */
export interface ServerInfo {
  name: string;
  version: string;
  projectRoot?: string;
}

/** MCP server capabilities returned by initialize. */
export interface ServerCapabilities {
  tools?: { listChanged: boolean };
  websocket?: {
    port: number;
    channels: string[];
  };
}

/** Initialize response from MCP server. */
export interface InitializeResult {
  protocolVersion: string;
  capabilities: ServerCapabilities;
  serverInfo: ServerInfo;
}

/** Log entry from notifications/log. */
export interface LogEntry {
  level: string;
  message: string;
  source: string;
  timestamp: string;
}

/** Network entry from notifications/network. */
export interface NetworkEntry {
  id: string;
  method: string;
  url: string;
  timestamp: string;
  duration_ms: number;
  status?: number;
  error?: string;
}

/** Parsed binary screenshot frame. */
export interface ScreenshotFrame {
  sequenceNumber: number;
  jpegData: Buffer;
}

/** JSON-RPC 2.0 request. */
export interface JsonRpcRequest {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
  id?: number;
}

/** JSON-RPC 2.0 success response. */
export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string | null;
  result?: unknown;
  error?: JsonRpcError;
}

/** JSON-RPC 2.0 error object. */
export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

/** JSON-RPC 2.0 notification (no id). */
export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
}

/** Events emitted by ApusClient. */
export interface ApusClientEvents {
  stateChange: (state: ConnectionState) => void;
  log: (entry: LogEntry) => void;
  network: (entry: NetworkEntry) => void;
  screenshotFrame: (frame: ScreenshotFrame) => void;
  serverInfo: (info: InitializeResult) => void;
  error: (err: Error) => void;
}
