import * as vscode from "vscode";
import { match } from "ts-pattern";
import { ApusClient } from "../apus-client";
import { ScreenshotFrame, ConnectionState } from "../types";
import {
  CHANNELS,
  DEFAULT_SCREENSHOT_FPS,
  DEFAULT_SCREENSHOT_SCALE,
  DEFAULT_SCREENSHOT_QUALITY,
  DEFAULT_IDLE_SCREENSHOT_FPS,
  DEFAULT_INTERACTION_BOOST_MS,
  DEFAULT_INTERACTION_STRICT_MODE,
} from "../constants";
import {
  InteractionTargetMode,
  LivePreviewInteractMessage,
  LivePreviewOutboundMessage,
  parseLivePreviewInboundMessage,
} from "./webview-messages";
import {
  describeCoordinateTarget,
  extractToolResultText,
  isCoordinateOnlyInteraction,
  InteractionTargetResolver,
  isToolResultError,
} from "./interaction-target-resolver";

/**
 * WebviewPanel that displays a live screenshot stream from the iOS app.
 *
 * Subscribes to the `screenshots` channel when visible,
 * unsubscribes when hidden or closed.
 */
export class LivePreviewPanel {
  private static instance: LivePreviewPanel | undefined;
  private static readonly hierarchyDepth = 16;
  private static readonly interactionToolTimeoutMs = 15_000;
  private readonly panel: vscode.WebviewPanel;
  private readonly extensionUri: vscode.Uri;
  private readonly client: ApusClient;
  private disposables: vscode.Disposable[] = [];

  private streamPaused = false;
  private streamMode: "active" | "idle" = "idle";
  private targetFps = 0;
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly targetResolver: InteractionTargetResolver;

  static createOrShow(extensionUri: vscode.Uri, client: ApusClient): void {
    if (LivePreviewPanel.instance) {
      LivePreviewPanel.instance.panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "apus.livePreview",
      "Apus Live Preview",
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [vscode.Uri.joinPath(extensionUri, "dist", "webviews")],
      }
    );

    LivePreviewPanel.instance = new LivePreviewPanel(panel, extensionUri, client);
  }

  private constructor(
    panel: vscode.WebviewPanel,
    extensionUri: vscode.Uri,
    client: ApusClient
  ) {
    this.panel = panel;
    this.extensionUri = extensionUri;
    this.client = client;
    this.targetResolver = new InteractionTargetResolver(client, LivePreviewPanel.hierarchyDepth);
    this.panel.webview.html = this.getHtml();

    this.panel.onDidChangeViewState(
      () => {
        if (this.panel.visible) {
          this.ensureStreaming();
        } else {
          this.cancelIdleTransition();
          this.unsubscribeScreenshots();
        }
      },
      null,
      this.disposables
    );

    const onFrame = (frame: ScreenshotFrame) => {
      const base64 = frame.jpegData.toString("base64");
      this.postWebviewMessage({
        type: "screenshot",
        data: base64,
        seq: frame.sequenceNumber,
      });
    };
    client.on("screenshotFrame", onFrame);
    this.disposables.push({ dispose: () => client.off("screenshotFrame", onFrame) });

    const onState = (state: ConnectionState) => {
      this.postWebviewMessage({ type: "connectionState", state });

      if (state === "connected") {
        this.ensureStreaming();
        return;
      }

      this.cancelIdleTransition();
      this.targetFps = 0;
      this.postStreamState();
    };
    client.on("stateChange", onState);
    this.disposables.push({ dispose: () => client.off("stateChange", onState) });

    this.postWebviewMessage({
      type: "connectionState",
      state: client.getState(),
    });
    this.postWebviewMessage({
      type: "config",
      scale: DEFAULT_SCREENSHOT_SCALE,
    });
    this.postStreamState();

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
            // Ignored in Live Preview panel; hierarchy requests are Inspector-only.
          })
          .with({ type: "previewChanges" }, () => {
            // Ignored in Live Preview panel; preview changes is Inspector-only.
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
        this.cancelIdleTransition();
        this.unsubscribeScreenshots();
        for (const d of this.disposables) {
          d.dispose();
        }
        LivePreviewPanel.instance = undefined;
      },
      null,
      this.disposables
    );

    this.ensureStreaming();
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
        { timeoutMs: LivePreviewPanel.interactionToolTimeoutMs }
      );

      if (!strictMode && resolved.usedHierarchyTargeting && isToolResultError(result)) {
        result = await this.client.callTool(
          "ui_interact",
          msg.args,
          { timeoutMs: LivePreviewPanel.interactionToolTimeoutMs }
        );
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
    } catch (err: unknown) {
      const error = err instanceof Error ? err.message : String(err);
      this.postWebviewMessage({
        type: "interactResult",
        id: msg.id,
        error,
        targetMode: "coordinate",
        targetDetail: describeCoordinateTarget(msg.args),
        targetFrame: undefined,
      });
    }
  }

  private ensureStreaming(): void {
    if (!this.panel.visible || this.streamPaused || this.client.getState() !== "connected") {
      this.postStreamState();
      return;
    }
    this.applyStreamMode("idle");
  }

  private pauseStream(): void {
    if (this.streamPaused) {
      return;
    }

    this.streamPaused = true;
    this.cancelIdleTransition();
    this.unsubscribeScreenshots();
    this.postStreamState();
  }

  private resumeStream(): void {
    if (!this.streamPaused) {
      return;
    }

    this.streamPaused = false;
    this.ensureStreaming();
  }

  private markInteractionActivity(): void {
    if (this.streamPaused || !this.panel.visible || this.client.getState() !== "connected") {
      return;
    }

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

    this.client
      .subscribe([CHANNELS.SCREENSHOTS], { fps, scale, quality })
      .catch(() => {});

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

  private unsubscribeScreenshots(): void {
    this.client.unsubscribe([CHANNELS.SCREENSHOTS]).catch(() => {});
    this.targetFps = 0;
    this.postStreamState();
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
      vscode.Uri.joinPath(this.extensionUri, "dist", "webviews", "live-preview.js")
    );

    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'nonce-${nonce}' ${this.panel.webview.cspSource};">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      width: 100vw;
      height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: var(--vscode-editor-background);
      overflow: hidden;
    }
    #preview-container {
      position: relative;
      max-width: 100%;
      max-height: 100%;
      line-height: 0;
    }
    #screenshot {
      max-width: 100vw;
      max-height: 100vh;
      object-fit: contain;
      image-rendering: -webkit-optimize-contrast;
      image-rendering: crisp-edges;
      display: none;
    }
    #interact-layer {
      position: absolute;
      inset: 0;
      cursor: crosshair;
      outline: none;
      z-index: 2;
    }
    #overlay {
      position: absolute;
      inset: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      background: var(--vscode-editor-background);
      color: var(--vscode-descriptionForeground);
      font-family: var(--vscode-font-family);
      font-size: 14px;
      z-index: 10;
    }
    #overlay.hidden { display: none; }
    #fps {
      position: fixed;
      bottom: 8px;
      right: 12px;
      font-family: var(--vscode-editor-font-family), monospace;
      font-size: 11px;
      color: var(--vscode-descriptionForeground);
      opacity: 0.6;
    }
    #stream-meta {
      position: fixed;
      bottom: 8px;
      left: 12px;
      font-family: var(--vscode-editor-font-family), monospace;
      font-size: 11px;
      color: var(--vscode-descriptionForeground);
      opacity: 0.8;
      z-index: 100;
    }
    #stream-toggle {
      position: fixed;
      bottom: 28px;
      left: 12px;
      z-index: 101;
      border: 1px solid var(--vscode-button-border, transparent);
      background: var(--vscode-button-secondaryBackground);
      color: var(--vscode-button-secondaryForeground);
      padding: 4px 8px;
      border-radius: 6px;
      font-size: 11px;
      font-family: var(--vscode-editor-font-family), monospace;
      cursor: pointer;
    }
    #stream-toggle:hover {
      background: var(--vscode-button-secondaryHoverBackground);
    }
    #stream-toggle.paused {
      background: var(--vscode-button-background);
      color: var(--vscode-button-foreground);
    }
    #target-badge {
      position: fixed;
      top: 8px;
      left: 12px;
      z-index: 102;
      border: 1px solid var(--vscode-panel-border);
      background: color-mix(in srgb, var(--vscode-editor-background) 88%, black);
      color: var(--vscode-descriptionForeground);
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-family: var(--vscode-editor-font-family), monospace;
      max-width: 56vw;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      opacity: 0.9;
    }
    .target-outline {
      position: absolute;
      border: 2px solid rgba(34, 197, 94, 0.92);
      border-radius: 6px;
      box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.45) inset;
      pointer-events: none;
      opacity: 0;
      transition: opacity 0.12s ease-out;
      z-index: 4;
    }
    .target-outline.visible {
      opacity: 1;
    }
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
    .ripple.double { background: rgba(249, 115, 22, 0.4); }
    @keyframes ripple-expand {
      to { transform: translate(-50%, -50%) scale(2.5); opacity: 0; }
    }
    .swipe-line {
      position: absolute;
      height: 3px;
      background: rgba(59, 130, 246, 0.6);
      transform-origin: 0 50%;
      animation: line-fade 0.3s 0.2s ease-out forwards;
      pointer-events: none;
    }
    @keyframes line-fade { to { opacity: 0; } }
    #toast {
      position: fixed;
      bottom: 30px;
      left: 50%;
      transform: translateX(-50%);
      background: rgba(0, 0, 0, 0.75);
      color: #fff;
      padding: 6px 16px;
      border-radius: 6px;
      font-size: 12px;
      font-family: var(--vscode-editor-font-family), monospace;
      z-index: 100;
      opacity: 0;
      transition: opacity 0.2s;
      pointer-events: none;
      max-width: 80%;
      text-align: center;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    #toast.show { opacity: 1; }
    #kbd-indicator {
      position: fixed;
      top: 8px;
      right: 12px;
      font-size: 11px;
      font-family: var(--vscode-editor-font-family), monospace;
      color: var(--vscode-descriptionForeground);
      opacity: 0;
      transition: opacity 0.2s;
      z-index: 100;
    }
    #kbd-indicator.active { opacity: 0.8; }
  </style>
</head>
<body>
  <div id="preview-container">
    <img id="screenshot" alt="iOS App Screenshot">
    <div id="interact-layer" tabindex="0"></div>
    <div id="overlay">Waiting for connection...</div>
  </div>
  <button id="stream-toggle" type="button">Pause Stream</button>
  <div id="stream-meta">stream: idle @ 0 fps</div>
  <div id="target-badge">target: --</div>
  <div id="toast"></div>
  <div id="kbd-indicator">Keyboard captured — Esc to release</div>
  <div id="fps"></div>
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

  private postWebviewMessage(message: LivePreviewOutboundMessage): void {
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
