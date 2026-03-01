import * as vscode from "vscode";
import { ApusClient } from "./apus-client";
import { StatusBar } from "./status-bar";
import { LivePreviewPanel } from "./panels/live-preview-panel";
import { LogViewerPanel } from "./panels/log-viewer-panel";
import { InspectorPanel } from "./panels/inspector-panel";
import { registerPreviewChangesCommand } from "./preview-changes";
import {
  DEFAULT_WS_HOST,
  DEFAULT_WS_PORT,
  DEFAULT_RECONNECT_INTERVAL_MS,
} from "./constants";

let client: ApusClient;
let statusBar: StatusBar;

export function activate(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("apus");
  const host = config.get<string>("wsHost", DEFAULT_WS_HOST);
  const port = config.get<number>("wsPort", DEFAULT_WS_PORT);
  const reconnectMs = config.get<number>(
    "reconnectIntervalMs",
    DEFAULT_RECONNECT_INTERVAL_MS
  );

  client = new ApusClient(host, port, reconnectMs);
  statusBar = new StatusBar();

  // Wire status bar to client state
  client.on("stateChange", (state) => {
    const name = client.getServerInfo()?.serverInfo?.name;
    statusBar.update(state, name);
  });

  client.on("serverInfo", (info) => {
    statusBar.update("connected", info.serverInfo.name);
  });

  client.on("error", (err) => {
    // Only log — reconnect is handled automatically
    console.error("[Apus]", err.message);
  });

  // Register commands
  context.subscriptions.push(
    vscode.commands.registerCommand("apus.connect", () => {
      if (client.getState() === "disconnected") {
        client.connect();
      }
    }),

    vscode.commands.registerCommand("apus.disconnect", () => {
      client.disconnect();
    }),

    vscode.commands.registerCommand("apus.showLivePreview", () => {
      LivePreviewPanel.createOrShow(context.extensionUri, client);
    }),

    vscode.commands.registerCommand("apus.showLogViewer", () => {
      LogViewerPanel.createOrShow(context.extensionUri, client);
    }),

    vscode.commands.registerCommand("apus.showInspector", () => {
      InspectorPanel.createOrShow(context.extensionUri, client);
    }),

    registerPreviewChangesCommand(context)
  );

  // React to settings changes
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("apus")) {
        const cfg = vscode.workspace.getConfiguration("apus");
        client.updateConfig(
          cfg.get<string>("wsHost", DEFAULT_WS_HOST),
          cfg.get<number>("wsPort", DEFAULT_WS_PORT),
          cfg.get<number>("reconnectIntervalMs", DEFAULT_RECONNECT_INTERVAL_MS)
        );
      }
    })
  );

  // Disposables
  context.subscriptions.push(statusBar);
  context.subscriptions.push({ dispose: () => client.dispose() });

  // Auto-connect
  if (config.get<boolean>("autoConnect", true)) {
    client.connect();
  }
}

export function deactivate(): void {
  client?.dispose();
  statusBar?.dispose();
}

/** Expose client for panels and tests. */
export function getClient(): ApusClient {
  return client;
}
