import * as vscode from "vscode";
import * as path from "path";
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
const DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS = 2000;
const DEFAULT_AUTO_PREVIEW_FILE_GLOBS = [
  "ExampleApp/*.swift",
  "ExampleApp/**/*.swift",
  "Sources/*.swift",
  "Sources/**/*.swift",
  "Package.swift",
  "ExampleApp/project.yml",
  "ExampleApp/build-and-run.sh",
];
const MIN_AUTO_PREVIEW_DEBOUNCE_MS = 100;
const MAX_AUTO_PREVIEW_DEBOUNCE_MS = 60000;

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

  // Auto preview on save (debounced)
  let autoPreviewTimer: ReturnType<typeof setTimeout> | null = null;
  let pendingAutoReason = "auto-save";

  const clearAutoPreviewTimer = (): void => {
    if (autoPreviewTimer) {
      clearTimeout(autoPreviewTimer);
      autoPreviewTimer = null;
    }
  };

  const scheduleAutoPreview = (reason: string, resource: vscode.Uri): void => {
    const cfg = vscode.workspace.getConfiguration("apus", resource);
    const debounceMs = clampNumber(
      cfg.get<number>("autoPreviewDebounceMs", DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS),
      MIN_AUTO_PREVIEW_DEBOUNCE_MS,
      MAX_AUTO_PREVIEW_DEBOUNCE_MS,
      DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS
    );

    const autoScriptPath = cfg.get<string>("autoPreviewScriptPath", "ExampleApp/build-and-run.sh --build")?.trim();

    pendingAutoReason = reason;
    clearAutoPreviewTimer();
    autoPreviewTimer = setTimeout(() => {
      autoPreviewTimer = null;
      void vscode.commands.executeCommand("apus.previewChanges", {
        source: "auto",
        reason: pendingAutoReason,
        scriptPathOverride: autoScriptPath || undefined,
      });
    }, debounceMs);
  };

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((document) => {
      const match = matchAutoPreviewDocument(document);
      if (!match.shouldRun) {
        return;
      }
      scheduleAutoPreview(`save:${match.relativePath}`, document.uri);
    })
  );
  context.subscriptions.push({ dispose: clearAutoPreviewTimer });

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

function matchAutoPreviewDocument(document: vscode.TextDocument): {
  shouldRun: boolean;
  relativePath: string;
} {
  const config = vscode.workspace.getConfiguration("apus", document.uri);
  if (!config.get<boolean>("autoPreviewOnSave", false)) {
    return { shouldRun: false, relativePath: "" };
  }

  if (document.isUntitled || document.uri.scheme !== "file") {
    return { shouldRun: false, relativePath: "" };
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
  if (!workspaceFolder) {
    return { shouldRun: false, relativePath: "" };
  }

  const relativePath = normalizeFsPath(
    path.relative(workspaceFolder.uri.fsPath, document.uri.fsPath)
  );
  if (!relativePath || relativePath.startsWith("..")) {
    return { shouldRun: false, relativePath: "" };
  }

  const configuredGlobs = config.get<string[]>(
    "autoPreviewFileGlobs",
    DEFAULT_AUTO_PREVIEW_FILE_GLOBS
  ) ?? DEFAULT_AUTO_PREVIEW_FILE_GLOBS;
  const globs = configuredGlobs
    .map((glob) => normalizeFsPath(glob.trim()))
    .filter((glob) => glob.length > 0);

  const shouldRun = globs.some((glob) => matchesGlob(relativePath, glob));
  return { shouldRun, relativePath };
}

function normalizeFsPath(value: string): string {
  return value.replace(/\\/g, "/").replace(/^\.\/+/, "");
}

function matchesGlob(relativePath: string, globPattern: string): boolean {
  const regex = globToRegExp(globPattern);
  return regex.test(relativePath);
}

function globToRegExp(globPattern: string): RegExp {
  const escaped = globPattern
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*\*/g, "__GLOBSTAR__")
    .replace(/\*/g, "[^/]*")
    .replace(/__GLOBSTAR__/g, ".*")
    .replace(/\?/g, "[^/]");
  return new RegExp(`^${escaped}$`);
}

function clampNumber(
  value: number | undefined,
  min: number,
  max: number,
  fallback: number
): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }
  return Math.max(min, Math.min(max, Math.floor(value)));
}
