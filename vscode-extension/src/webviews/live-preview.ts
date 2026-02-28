import type { ConnectionState } from "../types";

declare function acquireVsCodeApi(): {
  postMessage(message: unknown): void;
};

type TargetMode = "identifier" | "label" | "path" | "coordinate" | "fallback";

interface TargetFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

type HostMessage =
  | { type: "screenshot"; data: string; seq: number }
  | { type: "connectionState"; state: ConnectionState }
  | { type: "config"; scale: number }
  | { type: "streamState"; paused: boolean; mode: "active" | "idle"; targetFps: number }
  | {
      type: "interactResult";
      id: number;
      text?: string;
      error?: string;
      targetMode?: TargetMode;
      targetDetail?: string;
      targetFrame?: TargetFrame;
    };

type OutboundMessage =
  | { type: "interact"; id: number; args: Record<string, unknown> }
  | { type: "pauseStream" }
  | { type: "resumeStream" };

interface UiState {
  connectionState: ConnectionState;
  hasFrame: boolean;
  deviceScale: number;
  streamPaused: boolean;
  streamMode: "active" | "idle";
  targetFps: number;
}

type UiAction =
  | { type: "connectionState"; state: ConnectionState }
  | { type: "frameReceived" }
  | { type: "configUpdated"; scale: number }
  | { type: "streamStateUpdated"; paused: boolean; mode: "active" | "idle"; targetFps: number };

interface MouseState {
  startX: number;
  startY: number;
  startTime: number;
}

const MOVE_THRESHOLD = 10;
const DOUBLE_TAP_MS = 300;
const TAP_MAX_MS = 500;
const TYPE_DEBOUNCE = 150;

function main(): void {
  const vscode = acquireVsCodeApi();
  const img = requireElement<HTMLImageElement>("screenshot");
  const overlay = requireElement<HTMLDivElement>("overlay");
  const fpsEl = requireElement<HTMLDivElement>("fps");
  const streamMetaEl = requireElement<HTMLDivElement>("stream-meta");
  const targetBadgeEl = requireElement<HTMLDivElement>("target-badge");
  const streamToggleEl = requireElement<HTMLButtonElement>("stream-toggle");
  const interactLayer = requireElement<HTMLDivElement>("interact-layer");
  const toastEl = requireElement<HTMLDivElement>("toast");
  const kbdIndicator = requireElement<HTMLDivElement>("kbd-indicator");

  let frameCount = 0;
  let lastFpsTime = performance.now();
  let uiState: UiState = {
    connectionState: "connecting",
    hasFrame: false,
    deviceScale: 0.5,
    streamPaused: false,
    streamMode: "idle",
    targetFps: 0,
  };

  let mouseState: MouseState | null = null;
  let lastTapTime = 0;
  let lastTapCoord: { x: number; y: number } | null = null;
  let doubleTapTimer: number | null = null;

  let typeBuffer = "";
  let typeTimer: number | null = null;

  let toastTimer: number | null = null;
  let nextInteractId = 0;
  const pendingInteractions = new Set<number>();
  let lastTargetBadge = "target: --";
  let targetOutlineEl: HTMLDivElement | null = null;
  let targetOutlineTimer: number | null = null;

  const reduceUiState = (state: UiState, action: UiAction): UiState => {
    switch (action.type) {
      case "connectionState":
        return { ...state, connectionState: action.state };
      case "frameReceived":
        return { ...state, hasFrame: true };
      case "configUpdated":
        if (Number.isFinite(action.scale) && action.scale > 0) {
          return { ...state, deviceScale: action.scale };
        }
        return state;
      case "streamStateUpdated":
        return {
          ...state,
          streamPaused: action.paused,
          streamMode: action.mode,
          targetFps: Math.max(0, action.targetFps),
        };
      default:
        return state;
    }
  };

  const dispatchUi = (action: UiAction): void => {
    uiState = reduceUiState(uiState, action);
    renderUiState();
  };

  const renderUiState = (): void => {
    if (uiState.connectionState === "disconnected") {
      overlay.textContent = "Disconnected — reconnecting...";
      overlay.classList.remove("hidden");
    } else if (uiState.connectionState === "connecting") {
      overlay.textContent = "Connecting...";
      overlay.classList.remove("hidden");
    } else if (uiState.hasFrame) {
      overlay.classList.add("hidden");
    } else {
      overlay.textContent = "Connected — waiting for first frame...";
      overlay.classList.remove("hidden");
    }

    if (uiState.streamPaused) {
      streamToggleEl.textContent = "Resume Stream";
      streamToggleEl.classList.add("paused");
    } else {
      streamToggleEl.textContent = "Pause Stream";
      streamToggleEl.classList.remove("paused");
    }

    const streamStatus = uiState.streamPaused
      ? "paused"
      : `${uiState.streamMode} @ ${uiState.targetFps} fps`;
    streamMetaEl.textContent = `stream: ${streamStatus}`;
    targetBadgeEl.textContent = lastTargetBadge;
  };

  const updateFps = (): void => {
    const now = performance.now();
    const elapsed = now - lastFpsTime;
    if (elapsed >= 1000) {
      const fps = Math.round((frameCount / elapsed) * 1000);
      fpsEl.textContent = `${fps} fps`;
      frameCount = 0;
      lastFpsTime = now;
    }
  };

  const toDeviceCoords = (
    clientX: number,
    clientY: number
  ): { x: number; y: number } | null => {
    const nw = img.naturalWidth;
    const nh = img.naturalHeight;
    if (!nw || !nh) {
      return null;
    }

    const rect = img.getBoundingClientRect();
    const imgAspect = nw / nh;
    const boxAspect = rect.width / rect.height;

    let renderW: number;
    let renderH: number;
    let offsetX: number;
    let offsetY: number;

    if (imgAspect > boxAspect) {
      renderW = rect.width;
      renderH = rect.width / imgAspect;
      offsetX = 0;
      offsetY = (rect.height - renderH) / 2;
    } else {
      renderH = rect.height;
      renderW = rect.height * imgAspect;
      offsetX = (rect.width - renderW) / 2;
      offsetY = 0;
    }

    const relX = clientX - rect.left - offsetX;
    const relY = clientY - rect.top - offsetY;

    if (relX < 0 || relX > renderW || relY < 0 || relY > renderH) {
      return null;
    }

    return {
      x: Math.round((relX / renderW) * (nw / uiState.deviceScale)),
      y: Math.round((relY / renderH) * (nh / uiState.deviceScale)),
    };
  };

  const showToast = (text: string): void => {
    toastEl.textContent = text;
    toastEl.classList.add("show");
    if (toastTimer !== null) {
      window.clearTimeout(toastTimer);
    }
    toastTimer = window.setTimeout(() => {
      toastEl.classList.remove("show");
      toastTimer = null;
    }, 2500);
  };

  const targetMeta = (msg: { targetMode?: TargetMode; targetDetail?: string }): string => {
    if (!msg.targetMode) {
      return "";
    }

    const base = msg.targetMode === "identifier"
      ? "id"
      : msg.targetMode === "label"
        ? "label"
        : msg.targetMode === "path"
          ? "path"
          : msg.targetMode;
    const detail = msg.targetDetail ? ` ${msg.targetDetail}` : "";
    return ` [target ${base}${detail}]`;
  };

  const targetBadge = (msg: { targetMode?: TargetMode; targetDetail?: string }): string => {
    if (!msg.targetMode) {
      return lastTargetBadge;
    }
    const base = msg.targetMode === "identifier"
      ? "id"
      : msg.targetMode === "label"
        ? "label"
        : msg.targetMode === "path"
          ? "path"
          : msg.targetMode;
    const detail = msg.targetDetail ? ` ${shorten(msg.targetDetail, 42)}` : "";
    return `target: ${base}${detail}`;
  };

  const showTargetOutline = (frame: TargetFrame | undefined): void => {
    if (!frame || frame.width <= 0 || frame.height <= 0) {
      return;
    }

    const nw = img.naturalWidth;
    const nh = img.naturalHeight;
    if (!nw || !nh) {
      return;
    }

    const imgRect = img.getBoundingClientRect();
    const layerRect = interactLayer.getBoundingClientRect();
    const imgAspect = nw / nh;
    const boxAspect = imgRect.width / imgRect.height;

    let renderW: number;
    let renderH: number;
    let offsetX: number;
    let offsetY: number;

    if (imgAspect > boxAspect) {
      renderW = imgRect.width;
      renderH = imgRect.width / imgAspect;
      offsetX = 0;
      offsetY = (imgRect.height - renderH) / 2;
    } else {
      renderH = imgRect.height;
      renderW = imgRect.height * imgAspect;
      offsetX = (imgRect.width - renderW) / 2;
      offsetY = 0;
    }

    const framePxX = frame.x * uiState.deviceScale;
    const framePxY = frame.y * uiState.deviceScale;
    const framePxW = frame.width * uiState.deviceScale;
    const framePxH = frame.height * uiState.deviceScale;

    const drawX = offsetX + (framePxX / nw) * renderW;
    const drawY = offsetY + (framePxY / nh) * renderH;
    const drawW = (framePxW / nw) * renderW;
    const drawH = (framePxH / nh) * renderH;

    if (!Number.isFinite(drawX) || !Number.isFinite(drawY) || !Number.isFinite(drawW) || !Number.isFinite(drawH)) {
      return;
    }

    if (!targetOutlineEl) {
      targetOutlineEl = document.createElement("div");
      targetOutlineEl.className = "target-outline";
      interactLayer.appendChild(targetOutlineEl);
    }

    targetOutlineEl.style.left = `${imgRect.left - layerRect.left + drawX}px`;
    targetOutlineEl.style.top = `${imgRect.top - layerRect.top + drawY}px`;
    targetOutlineEl.style.width = `${drawW}px`;
    targetOutlineEl.style.height = `${drawH}px`;
    targetOutlineEl.classList.add("visible");

    if (targetOutlineTimer !== null) {
      window.clearTimeout(targetOutlineTimer);
    }
    targetOutlineTimer = window.setTimeout(() => {
      targetOutlineEl?.classList.remove("visible");
      targetOutlineTimer = null;
    }, 1500);
  };

  const showRipple = (clientX: number, clientY: number, isDouble: boolean): void => {
    const rect = interactLayer.getBoundingClientRect();
    const el = document.createElement("div");
    el.className = `ripple${isDouble ? " double" : ""}`;
    el.style.left = `${clientX - rect.left}px`;
    el.style.top = `${clientY - rect.top}px`;
    interactLayer.appendChild(el);
    el.addEventListener("animationend", () => {
      el.remove();
    });
  };

  const showSwipeLine = (x1: number, y1: number, x2: number, y2: number): void => {
    const rect = interactLayer.getBoundingClientRect();
    const rx1 = x1 - rect.left;
    const ry1 = y1 - rect.top;
    const dx = x2 - rect.left - rx1;
    const dy = y2 - rect.top - ry1;
    const len = Math.sqrt(dx * dx + dy * dy);
    const angle = (Math.atan2(dy, dx) * 180) / Math.PI;
    const el = document.createElement("div");
    el.className = "swipe-line";
    el.style.left = `${rx1}px`;
    el.style.top = `${ry1}px`;
    el.style.width = `${len}px`;
    el.style.transform = `rotate(${angle}deg)`;
    interactLayer.appendChild(el);
    window.setTimeout(() => {
      el.remove();
    }, 600);
  };

  const send = (message: OutboundMessage): void => {
    vscode.postMessage(message);
  };

  const sendInteraction = (args: Record<string, unknown>, pendingText: string): void => {
    const id = ++nextInteractId;
    showToast(pendingText);
    send({ type: "interact", args, id });
    pendingInteractions.add(id);
  };

  const flushTypeBuffer = (): void => {
    if (!typeBuffer) {
      return;
    }
    if (typeTimer !== null) {
      window.clearTimeout(typeTimer);
      typeTimer = null;
    }

    const text = typeBuffer;
    typeBuffer = "";
    const display = text.replace(/\n/g, "↵").replace(/[\b]/g, "⌫");
    sendInteraction({ action: "type_text", text }, `Typing "${display}"...`);
  };

  streamToggleEl.addEventListener("click", () => {
    send(uiState.streamPaused ? { type: "resumeStream" } : { type: "pauseStream" });
  });

  interactLayer.addEventListener("mousedown", (e) => {
    if (e.button !== 0) {
      return;
    }
    mouseState = { startX: e.clientX, startY: e.clientY, startTime: Date.now() };
    interactLayer.focus();
    e.preventDefault();
  });

  document.addEventListener("mouseup", (e) => {
    if (!mouseState) {
      return;
    }

    const dx = e.clientX - mouseState.startX;
    const dy = e.clientY - mouseState.startY;
    const dist = Math.sqrt(dx * dx + dy * dy);
    const elapsed = Date.now() - mouseState.startTime;
    const stateAtDown = mouseState;
    mouseState = null;

    if (dist > MOVE_THRESHOLD) {
      const startCoord = toDeviceCoords(stateAtDown.startX, stateAtDown.startY);
      const endCoord = toDeviceCoords(e.clientX, e.clientY);
      if (startCoord && endCoord) {
        const adx = Math.abs(endCoord.x - startCoord.x);
        const ady = Math.abs(endCoord.y - startCoord.y);
        const direction = adx > ady
          ? endCoord.x > startCoord.x
            ? "right"
            : "left"
          : endCoord.y > startCoord.y
            ? "down"
            : "up";
        showSwipeLine(stateAtDown.startX, stateAtDown.startY, e.clientX, e.clientY);
        sendInteraction(
          { action: "swipe", direction, coordinate: startCoord },
          `Swiping ${direction}...`
        );
      }

      if (doubleTapTimer !== null) {
        window.clearTimeout(doubleTapTimer);
        doubleTapTimer = null;
      }
      return;
    }

    if (elapsed >= TAP_MAX_MS) {
      return;
    }

    const coord = toDeviceCoords(e.clientX, e.clientY);
    if (!coord) {
      return;
    }

    const now = Date.now();
    if (lastTapCoord && now - lastTapTime < DOUBLE_TAP_MS) {
      if (doubleTapTimer !== null) {
        window.clearTimeout(doubleTapTimer);
        doubleTapTimer = null;
      }
      showRipple(e.clientX, e.clientY, true);
      sendInteraction(
        { action: "double_tap", coordinate: coord },
        `Double-tap at (${coord.x}, ${coord.y})...`
      );
      lastTapTime = 0;
      lastTapCoord = null;
      return;
    }

    lastTapTime = now;
    lastTapCoord = coord;
    const cx = e.clientX;
    const cy = e.clientY;
    const savedCoord = coord;
    doubleTapTimer = window.setTimeout(() => {
      doubleTapTimer = null;
      showRipple(cx, cy, false);
      sendInteraction(
        { action: "tap", coordinate: savedCoord },
        `Tap at (${savedCoord.x}, ${savedCoord.y})...`
      );
      lastTapCoord = null;
    }, DOUBLE_TAP_MS);
  });

  interactLayer.addEventListener("contextmenu", (e) => {
    e.preventDefault();
  });

  interactLayer.addEventListener("keydown", (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey) {
      return;
    }
    if (e.key === "Escape") {
      interactLayer.blur();
      return;
    }

    e.preventDefault();

    let ch = "";
    if (e.key === "Backspace") {
      ch = "\b";
    } else if (e.key === "Enter") {
      ch = "\n";
    } else if (e.key.length === 1) {
      ch = e.key;
    } else {
      return;
    }

    typeBuffer += ch;
    if (typeTimer !== null) {
      window.clearTimeout(typeTimer);
    }
    typeTimer = window.setTimeout(flushTypeBuffer, TYPE_DEBOUNCE);
  });

  interactLayer.addEventListener("focus", () => {
    kbdIndicator.classList.add("active");
  });

  interactLayer.addEventListener("blur", () => {
    kbdIndicator.classList.remove("active");
    flushTypeBuffer();
  });

  window.addEventListener("message", (event: MessageEvent<unknown>) => {
    const msg = parseHostMessage(event.data);
    if (!msg) {
      return;
    }

    switch (msg.type) {
      case "screenshot":
        img.src = `data:image/jpeg;base64,${msg.data}`;
        img.style.display = "block";
        frameCount++;
        updateFps();
        dispatchUi({ type: "frameReceived" });
        break;
      case "connectionState":
        dispatchUi({ type: "connectionState", state: msg.state });
        break;
      case "config":
        dispatchUi({ type: "configUpdated", scale: msg.scale });
        break;
      case "streamState":
        dispatchUi({
          type: "streamStateUpdated",
          paused: msg.paused,
          mode: msg.mode,
          targetFps: msg.targetFps,
        });
        break;
      case "interactResult":
        pendingInteractions.delete(msg.id);
        const meta = targetMeta(msg);
        lastTargetBadge = targetBadge(msg);
        targetBadgeEl.textContent = lastTargetBadge;
        showTargetOutline(msg.targetFrame);
        if (msg.error) {
          showToast(`Error: ${msg.error}${meta}`);
        } else if (msg.text) {
          showToast(`${msg.text}${meta}`);
        }
        break;
      default:
        assertNever(msg);
    }
  });

  renderUiState();
}

function parseHostMessage(value: unknown): HostMessage | null {
  if (!isRecord(value) || typeof value.type !== "string") {
    return null;
  }

  switch (value.type) {
    case "screenshot":
      if (typeof value.data === "string" && typeof value.seq === "number") {
        return { type: "screenshot", data: value.data, seq: value.seq };
      }
      return null;
    case "connectionState":
      if (isConnectionState(value.state)) {
        return { type: "connectionState", state: value.state };
      }
      return null;
    case "config":
      if (typeof value.scale === "number") {
        return { type: "config", scale: value.scale };
      }
      return null;
    case "streamState":
      if (
        typeof value.paused === "boolean" &&
        (value.mode === "active" || value.mode === "idle") &&
        typeof value.targetFps === "number"
      ) {
        return {
          type: "streamState",
          paused: value.paused,
          mode: value.mode,
          targetFps: value.targetFps,
        };
      }
      return null;
    case "interactResult":
      if (typeof value.id !== "number") {
        return null;
      }
      const targetMode = isTargetMode(value.targetMode) ? value.targetMode : undefined;
      const targetFrame = parseTargetFrame(value.targetFrame);
      return {
        type: "interactResult",
        id: value.id,
        text: typeof value.text === "string" ? value.text : undefined,
        error: typeof value.error === "string" ? value.error : undefined,
        targetMode,
        targetDetail: typeof value.targetDetail === "string" ? value.targetDetail : undefined,
        targetFrame,
      };
    default:
      return null;
  }
}

function isConnectionState(value: unknown): value is ConnectionState {
  return value === "disconnected" || value === "connecting" || value === "connected";
}

function isTargetMode(value: unknown): value is TargetMode {
  return (
    value === "identifier" ||
    value === "label" ||
    value === "path" ||
    value === "coordinate" ||
    value === "fallback"
  );
}

function parseTargetFrame(value: unknown): TargetFrame | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  const x = typeof value.x === "number" ? value.x : NaN;
  const y = typeof value.y === "number" ? value.y : NaN;
  const width = typeof value.width === "number" ? value.width : NaN;
  const height = typeof value.height === "number" ? value.height : NaN;

  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height)) {
    return undefined;
  }

  return { x, y, width, height };
}

function shorten(text: string, maxLen: number): string {
  if (text.length <= maxLen) {
    return text;
  }
  return `${text.slice(0, maxLen - 1)}...`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireElement<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`Missing element #${id}`);
  }
  return element as T;
}

function assertNever(_: never): never {
  throw new Error("Unhandled message variant");
}

main();
