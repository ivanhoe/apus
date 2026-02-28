import { EventEmitter } from "events";
import WebSocket from "ws";
import { match, P } from "ts-pattern";
import {
  ConnectionState,
  InitializeResult,
  LogEntry,
  NetworkEntry,
  ScreenshotFrame,
  JsonRpcRequest,
  JsonRpcResponse,
  JsonRpcNotification,
} from "./types";
import { NOTIFICATIONS, MCP_PROTOCOL_VERSION } from "./constants";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

interface SendRequestOptions {
  timeoutMs?: number;
}

export interface CallToolOptions {
  timeoutMs?: number;
}

type ConnectionEvent =
  | "connect_requested"
  | "initialized"
  | "connection_closed"
  | "disconnect_requested";

/**
 * WebSocket client for the Apus MCP server.
 *
 * Handles JSON-RPC 2.0 communication, binary screenshot frames,
 * automatic reconnection, and channel subscriptions.
 */
export class ApusClient extends EventEmitter {
  private static readonly defaultRequestTimeoutMs = 10_000;
  private ws: WebSocket | null = null;
  private state: ConnectionState = "disconnected";
  private serverInfo: InitializeResult | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private activeChannels = new Set<string>();
  private lastSubscribeOptions: Record<string, unknown> = {};
  private shouldReconnect = true;
  private disposed = false;

  constructor(
    private host: string,
    private port: number,
    private reconnectIntervalMs: number
  ) {
    super();
  }

  /** Current connection state. */
  getState(): ConnectionState {
    return this.state;
  }

  /** Server info from last successful initialize, or null. */
  getServerInfo(): InitializeResult | null {
    return this.serverInfo;
  }

  /** Open WebSocket connection and perform MCP initialize handshake. */
  connect(): void {
    if (this.state !== "disconnected" || this.disposed) {
      return;
    }

    this.shouldReconnect = true;
    this.cancelReconnect();
    this.transition("connect_requested");

    const url = `ws://${this.host}:${this.port}`;
    const ws = new WebSocket(url);
    this.ws = ws;

    ws.on("open", () => {
      if (ws !== this.ws || this.disposed || this.state !== "connecting") {
        ws.close();
        return;
      }

      this.performInitialize()
        .then(() => {
          if (ws !== this.ws || this.disposed || this.state !== "connecting") {
            return;
          }
          this.transition("initialized");
          void this.resubscribeActiveChannels();
        })
        .catch((err) => {
          if (ws !== this.ws) {
            return;
          }
          this.emit("error", err);
          ws.close();
        });
    });

    ws.on("message", (data: WebSocket.Data, isBinary: boolean) => {
      if (ws !== this.ws) {
        return;
      }
      if (isBinary) {
        this.handleBinaryMessage(data as Buffer);
      } else {
        this.handleTextMessage(data.toString());
      }
    });

    ws.on("close", () => {
      this.handleDisconnect(ws);
    });

    ws.on("error", (err) => {
      if (ws !== this.ws) {
        return;
      }
      this.emit("error", err);
      // 'close' event will follow — reconnect handled there
    });
  }

  /** Gracefully close the connection and stop reconnecting. */
  disconnect(): void {
    this.shouldReconnect = false;
    this.cancelReconnect();
    this.activeChannels.clear();
    this.lastSubscribeOptions = {};
    const ws = this.ws;
    this.ws = null;
    if (
      ws &&
      (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)
    ) {
      ws.close();
    }
    this.rejectAllPending("Client disconnected");
    this.transition("disconnect_requested");
  }

  /** Full cleanup — call on extension deactivate. */
  dispose(): void {
    this.disposed = true;
    this.disconnect();
    this.removeAllListeners();
  }

  /** Subscribe to one or more channels. */
  async subscribe(
    channels: string[],
    options?: Record<string, unknown>
  ): Promise<void> {
    for (const ch of channels) {
      this.activeChannels.add(ch);
    }
    if (options) {
      this.lastSubscribeOptions = { ...this.lastSubscribeOptions, ...options };
    }

    if (this.state !== "connected") {
      return; // Will subscribe on reconnect
    }

    await this.sendRequest("subscribe", {
      channels,
      ...(options ? { options } : {}),
    });
  }

  /** Unsubscribe from one or more channels. */
  async unsubscribe(channels: string[]): Promise<void> {
    for (const ch of channels) {
      this.activeChannels.delete(ch);
    }

    if (this.state !== "connected") {
      return;
    }

    await this.sendRequest("unsubscribe", { channels });
  }

  /** Call an MCP tool by name. */
  async callTool(
    name: string,
    args: Record<string, unknown> = {},
    options: CallToolOptions = {}
  ): Promise<unknown> {
    return this.sendRequest(
      "tools/call",
      { name, arguments: args },
      { timeoutMs: options.timeoutMs }
    );
  }

  /** Update connection parameters (e.g. from settings change). */
  updateConfig(host: string, port: number, reconnectMs: number): void {
    const changed = host !== this.host || port !== this.port;
    this.host = host;
    this.port = port;
    this.reconnectIntervalMs = reconnectMs;
    if (changed && this.state !== "disconnected") {
      this.disconnect();
      this.connect();
    }
  }

  // ── Internal ──────────────────────────────────────────────

  private setState(newState: ConnectionState): void {
    if (this.state !== newState) {
      this.state = newState;
      this.emit("stateChange", newState);
    }
  }

  private transition(event: ConnectionEvent): void {
    const nextState = match<[ConnectionState, ConnectionEvent]>([
      this.state,
      event,
    ])
      .with(["disconnected", "connect_requested"], () => "connecting" as const)
      .with(["connecting", "initialized"], () => "connected" as const)
      .with([P._, "connection_closed"], () => "disconnected" as const)
      .with([P._, "disconnect_requested"], () => "disconnected" as const)
      .otherwise(([current]) => current);

    this.setState(nextState);
  }

  private async performInitialize(): Promise<void> {
    const result = (await this.sendRequest("initialize", {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: "apus-vscode", version: "0.1.1" },
    })) as InitializeResult;

    this.serverInfo = result;
    this.emit("serverInfo", result);

    // Send initialized notification (no id, no response expected)
    this.sendNotification("notifications/initialized");
  }

  private async resubscribeActiveChannels(): Promise<void> {
    if (this.activeChannels.size === 0) {
      return;
    }
    const channels = Array.from(this.activeChannels);
    const options = Object.keys(this.lastSubscribeOptions).length > 0
      ? this.lastSubscribeOptions
      : undefined;
    try {
      await this.sendRequest("subscribe", {
        channels,
        ...(options ? { options } : {}),
      });
    } catch {
      // Non-fatal: subscriptions will retry on next reconnect
    }
  }

  private sendRequest(
    method: string,
    params: Record<string, unknown>,
    options: SendRequestOptions = {}
  ): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
        reject(new Error("Not connected"));
        return;
      }

      const id = this.nextId++;
      const request: JsonRpcRequest = {
        jsonrpc: "2.0",
        method,
        params,
        id,
      };

      const timeoutMsRaw = options.timeoutMs;
      const timeoutMs = typeof timeoutMsRaw === "number" && Number.isFinite(timeoutMsRaw)
        ? Math.max(1000, Math.floor(timeoutMsRaw))
        : ApusClient.defaultRequestTimeoutMs;

      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify(request));
    });
  }

  private sendNotification(method: string, params?: Record<string, unknown>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return;
    }
    const notification: JsonRpcNotification = {
      jsonrpc: "2.0",
      method,
      ...(params ? { params } : {}),
    };
    this.ws.send(JSON.stringify(notification));
  }

  private handleTextMessage(text: string): void {
    let msg: JsonRpcResponse | JsonRpcNotification;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    match(msg)
      .with({ id: P.when((id) => id != null) }, (response) => {
        this.handleResponse(response as JsonRpcResponse);
      })
      .otherwise((notification) => {
        this.handleNotification(notification as JsonRpcNotification);
      });
  }

  /** Parse binary screenshot frame: [4-byte LE sequence][JPEG data]. */
  handleBinaryMessage(data: Buffer): void {
    if (data.length < 5) {
      return; // Too small to contain header + any data
    }
    const sequenceNumber = data.readUInt32LE(0);
    const jpegData = data.subarray(4);
    this.emit("screenshotFrame", { sequenceNumber, jpegData } as ScreenshotFrame);
  }

  private handleDisconnect(ws: WebSocket): void {
    if (ws !== this.ws) {
      return; // Ignore stale sockets from prior connect attempts.
    }
    this.ws = null;
    this.rejectAllPending("Connection closed");
    this.transition("connection_closed");
    if (this.shouldReconnect) {
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.disposed || this.reconnectTimer || !this.shouldReconnect) {
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.disposed && this.state === "disconnected") {
        this.connect();
      }
    }, this.reconnectIntervalMs);
  }

  private cancelReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private rejectAllPending(reason: string): void {
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new Error(reason));
    }
    this.pending.clear();
  }

  private handleResponse(response: JsonRpcResponse): void {
    const id = this.parseResponseId(response.id);
    if (id == null) {
      return;
    }

    const pending = this.pending.get(id);
    if (!pending) {
      return;
    }

    this.pending.delete(id);
    clearTimeout(pending.timer);

    if (response.error) {
      pending.reject(new Error(`${response.error.message} (code ${response.error.code})`));
      return;
    }

    pending.resolve(response.result);
  }

  private parseResponseId(id: JsonRpcResponse["id"]): number | null {
    return match(id)
      .with(P.number, (value) => value)
      .with(P.string, (value) => {
        const parsed = Number.parseInt(value, 10);
        return Number.isNaN(parsed) ? null : parsed;
      })
      .otherwise(() => null);
  }

  private handleNotification(notification: JsonRpcNotification): void {
    match(notification)
      .with({ method: NOTIFICATIONS.LOG }, (value) => {
        this.emit("log", value.params as LogEntry);
      })
      .with({ method: NOTIFICATIONS.NETWORK }, (value) => {
        this.emit("network", value.params as NetworkEntry);
      })
      .otherwise(() => {
        // Ignore unknown notification methods.
      });
  }
}
