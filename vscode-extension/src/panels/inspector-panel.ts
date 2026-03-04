import * as vscode from "vscode";
import { match } from "ts-pattern";
import { ApusClient } from "../apus-client";
import { ConnectionState, LogEntry, NetworkEntry, ScreenshotFrame } from "../types";
import {
  CHANNELS,
  DEFAULT_IDLE_SCREENSHOT_FPS,
  DEFAULT_INTERACTION_BOOST_MS,
  DEFAULT_INTERACTION_STRICT_MODE,
  DEFAULT_LOG_BUFFER_SIZE,
  DEFAULT_SCREENSHOT_FPS,
  DEFAULT_SCREENSHOT_QUALITY,
  DEFAULT_SCREENSHOT_SCALE,
} from "../constants";
import {
  InspectorOutboundMessage,
  InteractionTargetMode,
  LivePreviewInteractMessage,
  parseLivePreviewInboundMessage,
} from "./webview-messages";
import {
  describeCoordinateTarget,
  extractToolResultText,
  isCoordinateOnlyInteraction,
  InteractionTargetResolver,
  isUnchangedToolResponse,
  isToolResultError,
} from "./interaction-target-resolver";

/**
 * Unified inspector panel: live preview + logs + network in one view.
 */
export class InspectorPanel {
  private static instance: InspectorPanel | undefined;

  private readonly panel: vscode.WebviewPanel;
  private readonly extensionUri: vscode.Uri;
  private readonly client: ApusClient;
  private readonly maxEntries: number;

  private readonly disposables: vscode.Disposable[] = [];

  private streamPaused = false;
  private streamMode: "active" | "idle" = "idle";
  private targetFps = 0;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly targetResolver: InteractionTargetResolver;
  private static readonly hierarchyDepth = 16;
  private static readonly hierarchyDepthPlan = [8, 12, 16] as const;
  private static readonly hierarchyRetryBackoffMs = [0, 180, 360] as const;
  private static readonly hierarchyToolTimeoutMs = 25_000;
  private static readonly interactionToolTimeoutMs = 15_000;
  private static readonly historyToolTimeoutMs = 10_000;
  private static readonly historyTailCap = 200;
  private lastHierarchySnapshot: Record<string, unknown> | null = null;

  private logBuffer: LogEntry[] = [];
  private networkBuffer: NetworkEntry[] = [];
  private historyWarmupDone = false;
  private historyWarmupPromise: Promise<void> | null = null;

  static createOrShow(extensionUri: vscode.Uri, client: ApusClient): void {
    if (InspectorPanel.instance) {
      InspectorPanel.instance.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "apus.inspector",
      "Apus Inspector",
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(extensionUri, "dist", "webviews")],
      }
    );

    InspectorPanel.instance = new InspectorPanel(panel, extensionUri, client);
  }

  private constructor(
    panel: vscode.WebviewPanel,
    extensionUri: vscode.Uri,
    client: ApusClient
  ) {
    this.panel = panel;
    this.extensionUri = extensionUri;
    this.client = client;
    this.targetResolver = new InteractionTargetResolver(client, InspectorPanel.hierarchyDepth);
    const configuredBuffer = vscode.workspace
      .getConfiguration("apus")
      .get<number>("logBufferSize", DEFAULT_LOG_BUFFER_SIZE);
    this.maxEntries = Math.max(1, Math.floor(configuredBuffer));

    this.panel.webview.html = this.getHtml();

    this.panel.onDidChangeViewState(
      () => {
        if (this.panel.visible) {
          this.ensureSubscriptions();
        } else {
          this.stopAllSubscriptions();
        }
      },
      null,
      this.disposables
    );

    const onFrame = (frame: ScreenshotFrame) => {
      const data = frame.jpegData.toString("base64");
      this.postWebviewMessage({ type: "screenshot", data, seq: frame.sequenceNumber });
    };
    this.client.on("screenshotFrame", onFrame);
    this.disposables.push({ dispose: () => this.client.off("screenshotFrame", onFrame) });

    const onLog = (entry: LogEntry) => {
      this.appendLog(entry);
      this.postWebviewMessage({ type: "log", entry });
    };
    this.client.on("log", onLog);
    this.disposables.push({ dispose: () => this.client.off("log", onLog) });

    const onNetwork = (entry: NetworkEntry) => {
      this.appendNetwork(entry);
      this.postWebviewMessage({ type: "network", entry });
    };
    this.client.on("network", onNetwork);
    this.disposables.push({ dispose: () => this.client.off("network", onNetwork) });

    const onState = (state: ConnectionState) => {
      this.postWebviewMessage({ type: "connectionState", state });

      if (state === "connected") {
        this.ensureSubscriptions();
        void this.postHierarchySnapshot();
      } else {
        this.cancelIdleTransition();
        this.targetFps = 0;
        this.postStreamState();
      }
    };
    this.client.on("stateChange", onState);
    this.disposables.push({ dispose: () => this.client.off("stateChange", onState) });

    this.panel.webview.onDidReceiveMessage(
      (rawMessage: unknown) => {
        const message = parseLivePreviewInboundMessage(rawMessage);
        if (!message) {
          return;
        }

        match(message)
          .with({ type: "interact" }, (msg) => {
            void this.handleInteractMessage(msg);
          })
          .with({ type: "requestHierarchy" }, () => {
            void this.postHierarchySnapshot();
          })
          .with({ type: "previewChanges" }, () => {
            void vscode.commands.executeCommand("apus.previewChanges");
          })
          .with({ type: "pauseStream" }, () => {
            this.pauseStream();
          })
          .with({ type: "resumeStream" }, () => {
            this.resumeStream();
          })
          .exhaustive();
      },
      null,
      this.disposables
    );

    this.panel.onDidDispose(
      () => {
        this.stopAllSubscriptions();
        for (const d of this.disposables) {
          d.dispose();
        }
        InspectorPanel.instance = undefined;
      },
      null,
      this.disposables
    );

    this.postWebviewMessage({ type: "connectionState", state: this.client.getState() });
    this.postWebviewMessage({ type: "config", scale: DEFAULT_SCREENSHOT_SCALE });
    this.postWebviewMessage({ type: "bulkLogs", entries: this.logBuffer });
    this.postWebviewMessage({ type: "bulkNetwork", entries: this.networkBuffer });
    this.postStreamState();
    void this.postHierarchySnapshot();

    this.ensureSubscriptions();
  }

  private appendLog(entry: LogEntry): void {
    this.logBuffer.push(entry);
    while (this.logBuffer.length > this.maxEntries) {
      this.logBuffer.shift();
    }
  }

  private appendNetwork(entry: NetworkEntry): void {
    this.networkBuffer.push(entry);
    while (this.networkBuffer.length > this.maxEntries) {
      this.networkBuffer.shift();
    }
  }

  private async handleInteractMessage(msg: LivePreviewInteractMessage): Promise<void> {
    this.markInteractionActivity();

    try {
      const { strictMode } = this.readInteractionConfig();
      const coordinateOnlyInteraction = isCoordinateOnlyInteraction(msg.args);
      const resolved = await this.targetResolver.resolve(msg.args, {
        allowPathTarget: !strictMode,
      });
      let targetMode: InteractionTargetMode = resolved.target?.mode ?? "coordinate";
      let targetDetail = resolved.target?.detail ?? describeCoordinateTarget(msg.args);
      let targetFrame = resolved.target?.frame;

      if (strictMode && coordinateOnlyInteraction && !resolved.target) {
        this.postWebviewMessage({
          type: "interactResult",
          id: msg.id,
          error:
            "Strict mode: semantic target not found for this interaction. Add accessibilityIdentifier/accessibilityLabel or disable apus.interactionStrictMode.",
          targetMode,
          targetDetail,
          targetFrame,
        });
        return;
      }

      let result = await this.client.callTool(
        "ui_interact",
        resolved.args,
        { timeoutMs: InspectorPanel.interactionToolTimeoutMs }
      );

      if (!strictMode && resolved.usedHierarchyTargeting && isToolResultError(result)) {
        const fallbackResult = await this.client.callTool(
          "ui_interact",
          msg.args,
          { timeoutMs: InspectorPanel.interactionToolTimeoutMs }
        );
        result = fallbackResult;
        targetMode = "fallback";
        targetDetail = describeCoordinateTarget(msg.args);
        targetFrame = undefined;
      }

      const text = extractToolResultText(result);
      const isError = isToolResultError(result);

      if (!isError) {
        this.targetResolver.invalidate();
      }

      if (isError) {
        this.postWebviewMessage({
          type: "interactResult",
          id: msg.id,
          error: text,
          targetMode,
          targetDetail,
          targetFrame,
        });
      } else {
        this.postWebviewMessage({
          type: "interactResult",
          id: msg.id,
          text,
          targetMode,
          targetDetail,
          targetFrame,
        });
      }
      void this.postHierarchySnapshot();
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.postWebviewMessage({
        type: "interactResult",
        id: msg.id,
        error: message,
        targetMode: "coordinate",
        targetDetail: describeCoordinateTarget(msg.args),
        targetFrame: undefined,
      });
    }
  }

  private async postHierarchySnapshot(): Promise<void> {
    if (this.client.getState() !== "connected") {
      this.postWebviewMessage({
        type: "hierarchy",
        hierarchy: null,
        error: "Not connected",
      });
      return;
    }

    try {
      const depthPlan = this.hierarchyRequestDepthPlan();
      let lastError = "Hierarchy request failed.";

      for (let attempt = 0; attempt < depthPlan.length; attempt++) {
        const depth = depthPlan[attempt];
        const cacheBust = attempt > 0 ? Date.now() + attempt : undefined;

        const initialResponse = await this.fetchHierarchyText(depth, cacheBust);
        if (initialResponse.error) {
          lastError = initialResponse.error;
          await this.waitBeforeHierarchyRetry(attempt, depthPlan.length);
          continue;
        }

        let text = initialResponse.text;
        if (!text) {
          lastError = "Hierarchy payload was empty.";
          await this.waitBeforeHierarchyRetry(attempt, depthPlan.length);
          continue;
        }

        if (isUnchangedToolResponse(text)) {
          if (this.lastHierarchySnapshot) {
            this.postWebviewMessage({
              type: "hierarchy",
              hierarchy: this.lastHierarchySnapshot,
            });
            return;
          }

          const forcedFreshResponse = await this.fetchHierarchyText(depth, Date.now() + attempt + 1);
          if (forcedFreshResponse.error || !forcedFreshResponse.text) {
            lastError = forcedFreshResponse.error ?? "Hierarchy refresh failed.";
            await this.waitBeforeHierarchyRetry(attempt, depthPlan.length);
            continue;
          }
          text = forcedFreshResponse.text;
        }

        if (isUnchangedToolResponse(text)) {
          lastError = "Hierarchy unchanged but no prior snapshot is available yet.";
          await this.waitBeforeHierarchyRetry(attempt, depthPlan.length);
          continue;
        }

        try {
          const parsed = JSON.parse(text) as unknown;
          const hierarchy = typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)
            ? parsed as Record<string, unknown>
            : null;

          if (hierarchy) {
            this.lastHierarchySnapshot = hierarchy;
            this.postWebviewMessage({
              type: "hierarchy",
              hierarchy,
            });
            return;
          }

          lastError = "Hierarchy payload was empty.";
        } catch (error: unknown) {
          lastError = error instanceof Error ? error.message : String(error);
        }

        await this.waitBeforeHierarchyRetry(attempt, depthPlan.length);
      }

      this.postWebviewMessage({
        type: "hierarchy",
        hierarchy: this.lastHierarchySnapshot,
        error: lastError,
      });
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      this.postWebviewMessage({
        type: "hierarchy",
        hierarchy: this.lastHierarchySnapshot,
        error: message,
      });
    }
  }

  private hierarchyRequestDepthPlan(): number[] {
    const uniqueDepths = new Set<number>([
      ...InspectorPanel.hierarchyDepthPlan,
      InspectorPanel.hierarchyDepth,
    ]);

    return Array.from(uniqueDepths)
      .filter((depth) => Number.isFinite(depth) && depth > 0)
      .sort((left, right) => left - right);
  }

  private async waitBeforeHierarchyRetry(attempt: number, totalAttempts: number): Promise<void> {
    if (attempt >= totalAttempts - 1) {
      return;
    }

    const backoff = InspectorPanel.hierarchyRetryBackoffMs[
      Math.min(attempt, InspectorPanel.hierarchyRetryBackoffMs.length - 1)
    ];
    if (backoff > 0) {
      await delay(backoff);
    }
  }

  private async fetchHierarchyText(
    depth: number,
    cacheBust?: number
  ): Promise<{ text: string | null; error: string | null }> {
    try {
      const raw = await this.client.callTool(
        "get_view_hierarchy",
        {
          format: "json",
          depth,
          include_hidden: false,
          ...(typeof cacheBust === "number" ? { cache_bust: cacheBust } : {}),
        },
        { timeoutMs: InspectorPanel.hierarchyToolTimeoutMs }
      );

      if (isToolResultError(raw)) {
        return { text: null, error: extractToolResultText(raw) };
      }

      const text = extractToolResultText(raw);
      if (!text) {
        return { text: null, error: "Hierarchy payload was empty." };
      }

      return { text, error: null };
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      return { text: null, error: message };
    }
  }

  private ensureSubscriptions(): void {
    if (!this.panel.visible || this.client.getState() !== "connected") {
      this.postStreamState();
      return;
    }

    this.ensureEventSubscriptions();
    this.ensureHistoryWarmup();

    if (this.streamPaused) {
      this.postStreamState();
      return;
    }

    this.applyStreamMode("idle");
  }

  private ensureEventSubscriptions(): void {
    this.client.subscribe([CHANNELS.LOGS, CHANNELS.NETWORK]).catch(() => {});
  }

  private ensureHistoryWarmup(): void {
    if (this.historyWarmupDone || this.historyWarmupPromise) {
      return;
    }

    if (this.logBuffer.length > 0 || this.networkBuffer.length > 0) {
      this.historyWarmupDone = true;
      return;
    }

    this.historyWarmupPromise = this.hydrateInitialEventHistory()
      .catch(() => {
        // Non-fatal: live subscriptions continue to stream new events.
      })
      .finally(() => {
        this.historyWarmupDone = true;
        this.historyWarmupPromise = null;
      });
  }

  private async hydrateInitialEventHistory(): Promise<void> {
    if (this.client.getState() !== "connected") {
      return;
    }

    const tail = Math.min(this.maxEntries, InspectorPanel.historyTailCap);
    const [logsResult, networkResult] = await Promise.all([
      this.client.callTool(
        "get_logs",
        { tail },
        { timeoutMs: InspectorPanel.historyToolTimeoutMs }
      ).catch(() => null),
      this.client.callTool(
        "get_network_history",
        { tail },
        { timeoutMs: InspectorPanel.historyToolTimeoutMs }
      ).catch(() => null),
    ]);

    if (logsResult && !isToolResultError(logsResult) && this.logBuffer.length === 0) {
      const logsText = extractToolResultText(logsResult);
      const parsedLogs = parseLogsFromToolText(logsText).slice(-this.maxEntries);
      if (parsedLogs.length > 0) {
        this.logBuffer = parsedLogs;
        this.postWebviewMessage({ type: "bulkLogs", entries: this.logBuffer });
      }
    }

    if (networkResult && !isToolResultError(networkResult) && this.networkBuffer.length === 0) {
      const networkText = extractToolResultText(networkResult);
      const parsedNetwork = parseNetworkFromToolText(networkText).slice(-this.maxEntries);
      if (parsedNetwork.length > 0) {
        this.networkBuffer = parsedNetwork;
        this.postWebviewMessage({ type: "bulkNetwork", entries: this.networkBuffer });
      }
    }
  }

  private unsubscribeEventSubscriptions(): void {
    this.client.unsubscribe([CHANNELS.LOGS, CHANNELS.NETWORK]).catch(() => {});
  }

  private pauseStream(): void {
    if (this.streamPaused) {
      return;
    }

    this.streamPaused = true;
    this.cancelIdleTransition();
    this.unsubscribeStream();
    this.postStreamState();
  }

  private resumeStream(): void {
    if (!this.streamPaused) {
      return;
    }

    this.streamPaused = false;
    this.ensureSubscriptions();
  }

  private markInteractionActivity(): void {
    if (this.streamPaused || !this.panel.visible || this.client.getState() !== "connected") {
      return;
    }

    this.ensureEventSubscriptions();
    this.applyStreamMode("active");
    this.scheduleIdleTransition();
  }

  private scheduleIdleTransition(): void {
    this.cancelIdleTransition();
    const { interactionBoostMs } = this.readStreamConfig();

    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;

      if (this.streamPaused || !this.panel.visible || this.client.getState() !== "connected") {
        return;
      }

      this.applyStreamMode("idle");
    }, interactionBoostMs);
  }

  private cancelIdleTransition(): void {
    if (!this.idleTimer) {
      return;
    }
    clearTimeout(this.idleTimer);
    this.idleTimer = null;
  }

  private applyStreamMode(mode: "active" | "idle"): void {
    const { activeFps, idleFps, scale, quality } = this.readStreamConfig();

    const fps = mode === "active" ? activeFps : idleFps;
    this.streamMode = mode;
    this.targetFps = fps;

    this.client.subscribe([CHANNELS.SCREENSHOTS], { fps, scale, quality }).catch(() => {});
    this.postWebviewMessage({ type: "config", scale });
    this.postStreamState();
  }

  private readStreamConfig(): {
    activeFps: number;
    idleFps: number;
    scale: number;
    quality: number;
    interactionBoostMs: number;
  } {
    const config = vscode.workspace.getConfiguration("apus");

    const activeFps = this.clampNumber(
      config.get<number>("screenshotFps", DEFAULT_SCREENSHOT_FPS),
      1,
      15,
      DEFAULT_SCREENSHOT_FPS
    );

    const idleFps = Math.min(
      activeFps,
      this.clampNumber(
        config.get<number>("idleScreenshotFps", DEFAULT_IDLE_SCREENSHOT_FPS),
        1,
        15,
        DEFAULT_IDLE_SCREENSHOT_FPS
      )
    );

    const interactionBoostMs = Math.round(
      this.clampNumber(
        config.get<number>("interactionBoostMs", DEFAULT_INTERACTION_BOOST_MS),
        300,
        20000,
        DEFAULT_INTERACTION_BOOST_MS
      )
    );

    const scale = this.clampNumber(
      config.get<number>("screenshotScale", DEFAULT_SCREENSHOT_SCALE),
      0.01,
      2,
      DEFAULT_SCREENSHOT_SCALE
    );

    const quality = this.clampNumber(
      config.get<number>("screenshotQuality", DEFAULT_SCREENSHOT_QUALITY),
      0,
      1,
      DEFAULT_SCREENSHOT_QUALITY
    );

    return { activeFps, idleFps, scale, quality, interactionBoostMs };
  }

  private readInteractionConfig(): { strictMode: boolean } {
    const config = vscode.workspace.getConfiguration("apus");
    return {
      strictMode: config.get<boolean>("interactionStrictMode", DEFAULT_INTERACTION_STRICT_MODE),
    };
  }

  private unsubscribeStream(): void {
    this.client.unsubscribe([CHANNELS.SCREENSHOTS]).catch(() => {});
    this.targetFps = 0;
    this.postStreamState();
  }

  private stopAllSubscriptions(): void {
    this.cancelIdleTransition();
    this.unsubscribeStream();
    this.unsubscribeEventSubscriptions();
  }

  private postStreamState(): void {
    this.postWebviewMessage({
      type: "streamState",
      paused: this.streamPaused,
      mode: this.streamMode,
      targetFps: this.targetFps,
    });
  }

  private getHtml(): string {
    const nonce = getNonce();
    const scriptUri = this.panel.webview.asWebviewUri(
      vscode.Uri.joinPath(this.extensionUri, "dist", "webviews", "inspector-panel.js")
    );

    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-${nonce}' ${this.panel.webview.cspSource};">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: var(--vscode-editor-background);
      color: var(--vscode-editor-foreground);
      font-family: var(--vscode-editor-font-family), monospace;
    }
    #root {
      display: grid;
      --side-pane-width: 420px;
      --splitter-width: 8px;
      grid-template-columns: minmax(320px, 1fr) var(--splitter-width) minmax(280px, var(--side-pane-width));
      width: 100%;
      height: 100%;
      min-height: 0;
      min-width: 0;
    }
    #preview-pane {
      position: relative;
      display: flex;
      flex-direction: column;
      align-items: stretch;
      justify-content: stretch;
      min-width: 0;
      min-height: 0;
      background: radial-gradient(circle at 20% 20%, rgba(30, 40, 80, 0.25), transparent 45%), var(--vscode-editor-background);
    }
    #pane-resizer {
      width: var(--splitter-width);
      min-width: var(--splitter-width);
      cursor: col-resize;
      user-select: none;
      touch-action: none;
      background: linear-gradient(
        90deg,
        color-mix(in srgb, var(--vscode-panel-border) 55%, transparent),
        color-mix(in srgb, var(--vscode-sideBar-background) 84%, black),
        color-mix(in srgb, var(--vscode-panel-border) 55%, transparent)
      );
    }
    #pane-resizer:hover {
      background: linear-gradient(
        90deg,
        color-mix(in srgb, var(--vscode-focusBorder) 42%, transparent),
        color-mix(in srgb, var(--vscode-sideBar-background) 84%, black),
        color-mix(in srgb, var(--vscode-focusBorder) 42%, transparent)
      );
    }
    #preview-toolbar {
      display: grid;
      grid-template-columns: auto 1fr;
      gap: 8px;
      align-items: center;
      padding: 8px 10px;
      border-bottom: 1px solid var(--vscode-panel-border);
      background: color-mix(in srgb, var(--vscode-sideBar-background) 94%, black);
      z-index: 12;
    }
    #preview-mode-group, #three-toolbar {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
      overflow: auto hidden;
    }
    #preview-toolbar button {
      border: none;
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      padding: 4px 8px;
      border-radius: 6px;
      font-size: 11px;
      cursor: pointer;
      white-space: nowrap;
    }
    #preview-toolbar button:hover {
      background: var(--vscode-button-secondaryHoverBackground);
    }
    #preview-toolbar button.active {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    #preview-toolbar button:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    #preview-container {
      position: relative;
      width: 100%;
      height: 100%;
      min-height: 0;
      line-height: 0;
      padding: 14px;
      flex: 1;
    }
    #scene-3d {
      position: absolute;
      inset: 14px;
      border-radius: 10px;
      border: 1px solid var(--vscode-panel-border);
      overflow: hidden;
      background: #0f1724;
      box-shadow: 0 18px 42px rgba(0, 0, 0, 0.35);
    }
    #scene-3d.hidden {
      display: none;
    }
    #screenshot {
      max-width: calc(100vw - var(--side-pane-width) - 52px);
      max-height: calc(100vh - 76px);
      object-fit: contain;
      image-rendering: -webkit-optimize-contrast;
      image-rendering: crisp-edges;
      display: block;
      border-radius: 10px;
      border: 1px solid var(--vscode-panel-border);
      box-shadow: 0 18px 42px rgba(0, 0, 0, 0.35);
      background: #111;
    }
    #screenshot.touch-hidden {
      display: none;
    }
    #screenshot.touch-visible {
      display: block;
    }
    #interact-layer {
      position: absolute;
      inset: 14px;
      cursor: crosshair;
      outline: none;
      z-index: 2;
      pointer-events: none;
    }
    #interact-layer.touch-enabled {
      pointer-events: auto;
    }
    #overlay {
      position: absolute;
      inset: 14px;
      display: flex;
      align-items: center;
      justify-content: center;
      background: color-mix(in srgb, var(--vscode-editor-background) 92%, black);
      color: var(--vscode-descriptionForeground);
      font-size: 13px;
      border: 1px dashed var(--vscode-panel-border);
      border-radius: 8px;
      z-index: 10;
    }
    #overlay.hidden { display: none; }
    #fps {
      position: absolute;
      right: 14px;
      bottom: 8px;
      font-size: 11px;
      opacity: 0.7;
    }
    #stream-meta {
      position: absolute;
      left: 14px;
      bottom: 8px;
      font-size: 11px;
      opacity: 0.75;
    }
    #stream-toggle {
      position: absolute;
      left: 14px;
      bottom: 28px;
      border: 1px solid var(--vscode-button-border, transparent);
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      padding: 5px 9px;
      border-radius: 6px;
      font-size: 11px;
      cursor: pointer;
      z-index: 12;
    }
    #stream-toggle:hover {
      background: var(--vscode-button-secondaryHoverBackground);
    }
    #stream-toggle.paused {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    #target-badge {
      position: absolute;
      top: 56px;
      left: 14px;
      border: 1px solid var(--vscode-panel-border);
      background: color-mix(in srgb, var(--vscode-editor-background) 88%, black);
      color: var(--vscode-descriptionForeground);
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 11px;
      max-width: 48%;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      z-index: 12;
      opacity: 0.9;
    }
    #three-meta {
      position: absolute;
      top: 56px;
      right: 14px;
      border: 1px solid var(--vscode-panel-border);
      background: color-mix(in srgb, var(--vscode-editor-background) 88%, black);
      color: var(--vscode-descriptionForeground);
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 11px;
      max-width: 48%;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      z-index: 12;
      opacity: 0.9;
    }
    #three-meta.hidden {
      display: none;
    }
    .target-outline {
      position: absolute;
      border: 2px solid rgba(34, 197, 94, 0.92);
      border-radius: 6px;
      box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.45) inset;
      pointer-events: none;
      opacity: 0;
      transition: opacity 0.12s ease-out;
      z-index: 5;
    }
    .target-outline.visible {
      opacity: 1;
    }
    #events-pane {
      display: flex;
      flex-direction: column;
      min-height: 0;
      min-width: 0;
      border-left: 1px solid var(--vscode-panel-border);
      background: linear-gradient(180deg, color-mix(in srgb, var(--vscode-sideBar-background) 92%, black), var(--vscode-editor-background));
    }
    #events-resizer {
      display: none;
      height: 10px;
      border-bottom: 1px solid var(--vscode-panel-border);
      background: linear-gradient(
        180deg,
        color-mix(in srgb, var(--vscode-sideBar-background) 82%, black),
        color-mix(in srgb, var(--vscode-editor-background) 86%, black)
      );
      cursor: row-resize;
      user-select: none;
      touch-action: none;
    }
    #events-resizer::after {
      content: "";
      display: block;
      width: 44px;
      height: 2px;
      border-radius: 999px;
      background: color-mix(in srgb, var(--vscode-descriptionForeground) 70%, white 5%);
      opacity: 0.65;
      margin: 3px auto 0;
    }
    #events-toolbar {
      display: grid;
      grid-template-columns: auto auto 1fr auto;
      gap: 6px;
      align-items: center;
      padding: 8px;
      border-bottom: 1px solid var(--vscode-panel-border);
      background: var(--vscode-sideBar-background);
    }
    #events-toolbar button {
      border: none;
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      padding: 4px 8px;
      border-radius: 6px;
      font-size: 11px;
      cursor: pointer;
    }
    #events-toolbar button.active {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    #events-toolbar input {
      width: 100%;
      border: 1px solid var(--vscode-input-border);
      background: var(--vscode-input-background);
      color: var(--vscode-input-foreground);
      font-size: 11px;
      padding: 5px 7px;
      border-radius: 6px;
    }
    #execute-toolbar {
      display: grid;
      grid-template-columns: auto auto auto auto 1fr;
      gap: 6px;
      align-items: center;
      padding: 7px 8px;
      border-bottom: 1px solid var(--vscode-panel-border);
      background: var(--vscode-sideBar-background);
    }
    #execute-toolbar button {
      border: none;
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      padding: 4px 8px;
      border-radius: 6px;
      font-size: 11px;
      cursor: pointer;
    }
    #execute-toolbar button.active {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    #execute-toolbar button:disabled {
      opacity: 0.55;
      cursor: not-allowed;
    }
    #execute-meta {
      font-size: 11px;
      color: var(--vscode-descriptionForeground);
      text-align: right;
      overflow: hidden;
      white-space: nowrap;
      text-overflow: ellipsis;
    }
    #events-status {
      font-size: 11px;
      color: var(--vscode-descriptionForeground);
      border-bottom: 1px solid var(--vscode-panel-border);
      padding: 6px 8px;
      background: var(--vscode-sideBar-background);
    }
    .events-list {
      flex: 1;
      overflow: auto;
      min-height: 0;
      padding: 6px 0;
    }
    .events-list.hidden { display: none; }
    .entry {
      padding: 5px 10px;
      border-bottom: 1px solid color-mix(in srgb, var(--vscode-panel-border) 65%, transparent);
      font-size: 11px;
      line-height: 1.4;
      word-break: break-word;
      white-space: pre-wrap;
    }
    .entry.hidden { display: none; }
    .entry:hover {
      background: var(--vscode-list-hoverBackground);
    }
    .entry.selected {
      background: color-mix(in srgb, var(--vscode-list-activeSelectionBackground) 28%, transparent);
      outline: 1px solid color-mix(in srgb, var(--vscode-list-activeSelectionBackground) 75%, white 10%);
      outline-offset: -1px;
    }
    .entry .meta {
      opacity: 0.68;
    }
    .entry .title {
      font-weight: 700;
      margin-right: 6px;
    }
    .entry.error {
      color: var(--vscode-errorForeground);
    }
    .entry.warn {
      color: var(--vscode-editorWarning-foreground);
    }
    #network-detail {
      border-top: 1px solid var(--vscode-panel-border);
      background: color-mix(in srgb, var(--vscode-editor-background) 93%, black);
      padding: 8px;
      max-height: 34%;
      min-height: 78px;
      overflow: auto;
      font-size: 11px;
      line-height: 1.38;
    }
    #network-detail.hidden {
      display: none;
    }
    #network-detail-title {
      font-size: 11px;
      opacity: 0.8;
      margin-bottom: 6px;
    }
    #network-detail-body {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      font-family: var(--vscode-editor-font-family), monospace;
    }
    #toast {
      position: fixed;
      bottom: 20px;
      left: 50%;
      transform: translateX(-50%);
      max-width: 72%;
      text-align: center;
      background: rgba(0, 0, 0, 0.76);
      color: #fff;
      padding: 7px 16px;
      border-radius: 7px;
      font-size: 12px;
      opacity: 0;
      transition: opacity 0.2s;
      pointer-events: none;
      z-index: 100;
    }
    #toast.show { opacity: 1; }
    #kbd-indicator {
      position: absolute;
      top: 8px;
      right: 14px;
      font-size: 11px;
      opacity: 0;
      transition: opacity 0.2s;
      z-index: 12;
    }
    #kbd-indicator.active { opacity: 0.8; }
    .ripple {
      position: absolute;
      width: 40px;
      height: 40px;
      border-radius: 50%;
      background: rgba(59, 130, 246, 0.4);
      transform: translate(-50%, -50%) scale(0);
      animation: ripple-expand 0.4s ease-out forwards;
      pointer-events: none;
    }
    .ripple.double { background: rgba(249, 115, 22, 0.42); }
    @keyframes ripple-expand {
      to { transform: translate(-50%, -50%) scale(2.5); opacity: 0; }
    }
    .swipe-line {
      position: absolute;
      height: 3px;
      background: rgba(59, 130, 246, 0.65);
      transform-origin: 0 50%;
      animation: line-fade 0.3s 0.2s ease-out forwards;
      pointer-events: none;
    }
    @keyframes line-fade { to { opacity: 0; } }
    @media (max-width: 980px) {
      #root {
        grid-template-columns: 1fr;
        grid-template-rows: minmax(300px, 1fr) minmax(170px, var(--stacked-events-height, 220px));
      }
      #preview-pane {
        border-right: none;
        border-bottom: 1px solid var(--vscode-panel-border);
      }
      #pane-resizer {
        display: none;
      }
      #events-pane {
        border-left: none;
      }
      #screenshot {
        max-width: calc(100vw - 24px);
        max-height: calc(64vh - 70px);
      }
      #events-resizer {
        display: block;
      }
    }
  </style>
</head>
<body>
  <div id="root">
    <section id="preview-pane">
      <div id="preview-toolbar">
        <div id="preview-mode-group">
          <button id="mode-3d" class="active" type="button">3D</button>
          <button id="mode-touch" type="button">Touch</button>
        </div>
        <div id="three-toolbar">
          <button id="three-fit" type="button">Fit</button>
          <button id="three-focus" type="button" disabled>Focus</button>
          <button id="three-top" type="button">Top</button>
          <button id="three-front" type="button">Front</button>
          <button id="three-refresh" type="button">Refresh 3D</button>
          <button id="preview-changes" type="button">Preview Changes</button>
        </div>
      </div>
      <div id="preview-container">
        <div id="scene-3d"></div>
        <img id="screenshot" class="touch-hidden" alt="iOS App Screenshot">
        <div id="interact-layer" tabindex="0"></div>
        <div id="overlay">Waiting for connection...</div>
      </div>
      <button id="stream-toggle" type="button">Pause Stream</button>
      <div id="stream-meta">stream: idle @ 0 fps</div>
      <div id="target-badge">target: --</div>
      <div id="three-meta">3D: waiting for hierarchy...</div>
      <div id="fps"></div>
      <div id="kbd-indicator">Keyboard captured — Esc to release</div>
    </section>
    <div id="pane-resizer" title="Drag to resize preview and logs panel"></div>

    <aside id="events-pane" data-max-entries="${this.maxEntries}">
      <div id="events-resizer" title="Drag to resize logs panel"></div>
      <div id="events-toolbar">
        <button id="tab-logs" data-tab="logs" class="active">Logs</button>
        <button id="tab-network" data-tab="network">Network</button>
        <input id="search" type="text" placeholder="Filter by text...">
        <button id="auto-scroll" class="active">Auto</button>
      </div>
      <div id="execute-toolbar">
        <button id="exec-record">Record</button>
        <button id="exec-stop" disabled>Stop</button>
        <button id="exec-play">Run</button>
        <button id="exec-clear">Clear</button>
        <div id="execute-meta">steps: 0</div>
      </div>
      <div id="events-status">Waiting for connection...</div>
      <div id="logs-list" class="events-list"></div>
      <div id="network-list" class="events-list hidden"></div>
      <div id="network-detail" class="hidden">
        <div id="network-detail-title">Request detail</div>
        <pre id="network-detail-body">Select a network row to inspect details.</pre>
      </div>
    </aside>
  </div>

  <div id="toast"></div>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
  }

  private clampNumber(
    value: number,
    min: number,
    max: number,
    fallback: number
  ): number {
    if (!Number.isFinite(value)) {
      return fallback;
    }
    return Math.min(max, Math.max(min, value));
  }

  private postWebviewMessage(message: InspectorOutboundMessage): void {
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

function parseLogsFromToolText(text: string): LogEntry[] {
  if (!text) {
    return [];
  }

  if (text.startsWith("No log entries") || text.startsWith("No new log entries")) {
    return [];
  }

  const body = extractToolBody(text);
  const entries: LogEntry[] = [];

  for (const rawLine of body.split("\n")) {
    const line = rawLine.trim();
    if (!line.startsWith("[")) {
      continue;
    }

    const match = line.match(/^\[(.+?)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s*(.*)$/);
    if (!match) {
      continue;
    }

    entries.push({
      timestamp: match[1],
      level: match[2].toLowerCase(),
      source: match[3],
      message: match[4],
    });
  }

  return entries;
}

function parseNetworkFromToolText(text: string): NetworkEntry[] {
  if (!text) {
    return [];
  }

  if (text.startsWith("No network requests") || text.startsWith("No new network requests")) {
    return [];
  }

  const body = extractToolBody(text);
  const entries: NetworkEntry[] = [];
  const blocks = body
    .split("\n---\n")
    .map((block) => block.trim())
    .filter((block) => block.length > 0);

  for (const block of blocks) {
    const lines = block.split("\n").map((line) => line.trim());
    if (lines.length === 0) {
      continue;
    }

    const headerMatch = lines[0].match(/^\[(.+?)\]\s+([A-Za-z]+)\s+(.+?)\s+\(id:\s*([^)]+)\)$/);
    if (!headerMatch) {
      continue;
    }

    let status: number | undefined;
    let durationMs = 0;
    let error: string | undefined;

    for (const line of lines.slice(1)) {
      const statusMatch = line.match(/^Status:\s*(.+?)\s+\|\s+Duration:\s*([0-9]+(?:\.[0-9]+)?)ms$/);
      if (statusMatch) {
        const parsedStatus = Number.parseInt(statusMatch[1], 10);
        if (Number.isFinite(parsedStatus)) {
          status = parsedStatus;
        }
        durationMs = Math.round(Number.parseFloat(statusMatch[2]));
        continue;
      }

      const errorMatch = line.match(/^Error:\s*(.*)$/);
      if (errorMatch) {
        const value = errorMatch[1].trim();
        if (value.length > 0) {
          error = value;
        }
      }
    }

    entries.push({
      id: headerMatch[4],
      method: headerMatch[2].toUpperCase(),
      url: headerMatch[3],
      timestamp: headerMatch[1],
      duration_ms: durationMs,
      ...(status !== undefined ? { status } : {}),
      ...(error ? { error } : {}),
    });
  }

  return entries;
}

function extractToolBody(text: string): string {
  const separatorIndex = text.indexOf("\n\n");
  if (separatorIndex < 0) {
    return text.trim();
  }
  return text.slice(separatorIndex + 2).trim();
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, Math.max(0, ms));
  });
}
