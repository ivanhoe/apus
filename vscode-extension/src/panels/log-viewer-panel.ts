import * as vscode from "vscode";
import { match } from "ts-pattern";
import { ApusClient } from "../apus-client";
import { LogEntry, ConnectionState } from "../types";
import { CHANNELS, DEFAULT_LOG_BUFFER_SIZE } from "../constants";
import {
  LogViewerOutboundMessage,
  parseLogViewerInboundMessage,
} from "./webview-messages";

/**
 * WebviewPanel that displays real-time logs from the iOS app.
 *
 * Features: level filtering, text search, auto-scroll, pause, clear, export.
 * Subscribes to the `logs` channel when visible.
 */
export class LogViewerPanel {
  private static instance: LogViewerPanel | undefined;
  private readonly panel: vscode.WebviewPanel;
  private readonly extensionUri: vscode.Uri;
  private readonly client: ApusClient;
  private disposables: vscode.Disposable[] = [];
  private logBuffer: LogEntry[] = [];
  private readonly maxEntries: number;
  private paused = false;
  private pausedEntries: LogEntry[] = [];

  static createOrShow(extensionUri: vscode.Uri, client: ApusClient): void {
    if (LogViewerPanel.instance) {
      LogViewerPanel.instance.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "apus.logViewer",
      "Apus Log Viewer",
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(extensionUri, "dist", "webviews")],
      }
    );

    LogViewerPanel.instance = new LogViewerPanel(panel, extensionUri, client);
  }

  private constructor(
    panel: vscode.WebviewPanel,
    extensionUri: vscode.Uri,
    client: ApusClient
  ) {
    this.panel = panel;
    this.extensionUri = extensionUri;
    this.client = client;

    const bufferSize = vscode.workspace
      .getConfiguration("apus")
      .get<number>("logBufferSize", DEFAULT_LOG_BUFFER_SIZE);
    this.maxEntries = Math.max(1, Math.floor(bufferSize));
    this.panel.webview.html = this.getHtml(this.maxEntries);

    // Handle log entries
    const onLog = (entry: LogEntry) => {
      this.logBuffer.push(entry);
      if (this.logBuffer.length > this.maxEntries) {
        this.logBuffer.shift();
      }
      if (this.paused) {
        this.pausedEntries.push(entry);
      } else {
        this.postWebviewMessage({ type: "log", entry });
      }
    };
    client.on("log", onLog);
    this.disposables.push({ dispose: () => client.off("log", onLog) });

    // Connection state
    const onState = (state: ConnectionState) => {
      this.postWebviewMessage({ type: "connectionState", state });
    };
    client.on("stateChange", onState);
    this.disposables.push({ dispose: () => client.off("stateChange", onState) });

    // Messages from webview
    this.panel.webview.onDidReceiveMessage(
      (rawMessage: unknown) => {
        const message = parseLogViewerInboundMessage(rawMessage);
        if (!message) {
          return;
        }

        void match(message)
          .with({ type: "pause" }, () => {
            this.paused = true;
            this.pausedEntries = [];
          })
          .with({ type: "resume" }, () => {
            this.paused = false;
            if (this.pausedEntries.length > 0) {
              // Send only entries received while paused.
              this.postWebviewMessage({
                type: "bulk",
                entries: this.pausedEntries,
              });
              this.pausedEntries = [];
            }
          })
          .with({ type: "clear" }, () => {
            this.logBuffer = [];
            this.pausedEntries = [];
          })
          .with({ type: "export" }, () => {
            void this.exportLogs();
          })
          .exhaustive();
      },
      null,
      this.disposables
    );

    // Send initial state
    this.postWebviewMessage({
      type: "connectionState",
      state: client.getState(),
    });

    // Visibility → subscribe/unsubscribe
    this.panel.onDidChangeViewState(
      () => {
        if (this.panel.visible) {
          this.subscribeLogs();
        } else {
          this.unsubscribeLogs();
        }
      },
      null,
      this.disposables
    );

    // Cleanup
    this.panel.onDidDispose(
      () => {
        this.unsubscribeLogs();
        for (const d of this.disposables) {
          d.dispose();
        }
        LogViewerPanel.instance = undefined;
      },
      null,
      this.disposables
    );

    // Subscribe now if connected
    if (client.getState() === "connected") {
      this.subscribeLogs();
    }

    // Auto-subscribe on reconnect
    const onConnected = (state: ConnectionState) => {
      if (state === "connected" && this.panel.visible) {
        this.subscribeLogs();
      }
    };
    client.on("stateChange", onConnected);
    this.disposables.push({ dispose: () => client.off("stateChange", onConnected) });
  }

  private subscribeLogs(): void {
    this.client.subscribe([CHANNELS.LOGS]).catch(() => {});
  }

  private unsubscribeLogs(): void {
    this.client.unsubscribe([CHANNELS.LOGS]).catch(() => {});
  }

  private async exportLogs(): Promise<void> {
    const uri = await vscode.window.showSaveDialog({
      defaultUri: vscode.Uri.file("apus-logs.txt"),
      filters: { "Text files": ["txt"], "JSON files": ["json"] },
    });
    if (!uri) {
      return;
    }

    const isJson = uri.fsPath.endsWith(".json");
    let content: string;
    if (isJson) {
      content = JSON.stringify(this.logBuffer, null, 2);
    } else {
      content = this.logBuffer
        .map((e) => `[${formatTime(e.timestamp)}] [${e.level.toUpperCase().padEnd(7)}] [${e.source}] ${e.message}`)
        .join("\n");
    }

    await vscode.workspace.fs.writeFile(uri, Buffer.from(content, "utf-8"));
    vscode.window.showInformationMessage(`Exported ${this.logBuffer.length} log entries.`);
  }

  private getHtml(maxEntries: number): string {
    const nonce = getNonce();
    const scriptUri = this.panel.webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "dist", "webviews", "log-viewer.js")
    );

    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}' ${this.panel.webview.cspSource};">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: var(--vscode-editor-font-family), monospace;
      font-size: 12px;
      color: var(--vscode-editor-foreground);
      background: var(--vscode-editor-background);
      display: flex;
      flex-direction: column;
      height: 100vh;
    }
    .toolbar {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 6px 10px;
      background: var(--vscode-sideBar-background);
      border-bottom: 1px solid var(--vscode-panel-border);
      flex-shrink: 0;
      flex-wrap: wrap;
    }
    .toolbar button {
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      border: none;
      padding: 3px 8px;
      border-radius: 3px;
      cursor: pointer;
      font-size: 11px;
      font-family: inherit;
    }
    .toolbar button:hover {
      background: var(--vscode-button-secondaryHoverBackground);
    }
    .toolbar button.active {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    .toolbar input {
      background: var(--vscode-input-background);
      color: var(--vscode-input-foreground);
      border: 1px solid var(--vscode-input-border);
      padding: 3px 6px;
      border-radius: 3px;
      font-size: 11px;
      font-family: inherit;
      flex: 1;
      min-width: 100px;
      max-width: 250px;
    }
    .spacer { flex: 1; }
    #logs {
      flex: 1;
      overflow-y: auto;
      padding: 4px 0;
    }
    .log-entry {
      padding: 1px 10px;
      white-space: pre-wrap;
      word-break: break-all;
      line-height: 1.5;
    }
    .log-entry:hover {
      background: var(--vscode-list-hoverBackground);
    }
    .log-entry.hidden { display: none; }
    .level-error { color: var(--vscode-errorForeground); }
    .level-warning { color: var(--vscode-editorWarning-foreground); }
    .level-info { color: var(--vscode-editorInfo-foreground); }
    .level-debug { color: var(--vscode-descriptionForeground); }
    .timestamp { opacity: 0.6; }
    .source { opacity: 0.7; }
    #status {
      padding: 4px 10px;
      font-size: 11px;
      color: var(--vscode-descriptionForeground);
      border-top: 1px solid var(--vscode-panel-border);
      background: var(--vscode-sideBar-background);
      flex-shrink: 0;
    }
  </style>
</head>
<body data-max-entries="${maxEntries}">
  <div class="toolbar">
    <button id="btnAll" class="active" data-level="all">All</button>
    <button id="btnDebug" data-level="debug">Debug</button>
    <button id="btnInfo" data-level="info">Info</button>
    <button id="btnWarning" data-level="warning">Warning</button>
    <button id="btnError" data-level="error">Error</button>
    <input id="search" type="text" placeholder="Search logs...">
    <div class="spacer"></div>
    <button id="btnAutoScroll" class="active">Auto-scroll</button>
    <button id="btnPause">Pause</button>
    <button id="btnClear">Clear</button>
    <button id="btnExport">Export</button>
  </div>
  <div id="logs"></div>
  <div id="status">Waiting for connection...</div>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
  }

  private postWebviewMessage(message: LogViewerOutboundMessage): void {
    void this.panel.webview.postMessage(message);
  }
}

function getNonce(): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  for (let i = 0; i < 32; i++) {
    out += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return out;
}

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleTimeString("en-US", {
      hour12: false,
      fractionalSecondDigits: 3,
    } as Intl.DateTimeFormatOptions);
  } catch {
    return iso;
  }
}
