import type { ConnectionState } from "../types";
import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";

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
  | { type: "hierarchy"; hierarchy: Record<string, unknown> | null; error?: string }
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
    }
  | { type: "log"; entry: Record<string, unknown> }
  | { type: "bulkLogs"; entries: Record<string, unknown>[] }
  | { type: "network"; entry: Record<string, unknown> }
  | { type: "bulkNetwork"; entries: Record<string, unknown>[] };

type OutboundMessage =
  | { type: "interact"; id: number; args: Record<string, unknown> }
  | { type: "pauseStream" }
  | { type: "resumeStream" }
  | { type: "requestHierarchy" }
  | { type: "previewChanges" };

type ActiveTab = "logs" | "network";
type PreviewMode = "three" | "touch";

interface UiState {
  connectionState: ConnectionState;
  hasFrame: boolean;
  hasHierarchy: boolean;
  deviceScale: number;
  streamPaused: boolean;
  streamMode: "active" | "idle";
  previewMode: PreviewMode;
  targetFps: number;
  activeTab: ActiveTab;
  autoScroll: boolean;
  searchText: string;
  logCount: number;
  networkCount: number;
}

type UiAction =
  | { type: "connectionState"; state: ConnectionState }
  | { type: "frameReceived" }
  | { type: "hierarchyUpdated"; hasHierarchy: boolean }
  | { type: "configUpdated"; scale: number }
  | { type: "streamStateUpdated"; paused: boolean; mode: "active" | "idle"; targetFps: number }
  | { type: "setPreviewMode"; mode: PreviewMode }
  | { type: "setActiveTab"; tab: ActiveTab }
  | { type: "toggleAutoScroll" }
  | { type: "setSearchText"; text: string }
  | { type: "setLogCount"; count: number }
  | { type: "setNetworkCount"; count: number };

interface MouseState {
  startX: number;
  startY: number;
  startTime: number;
}

interface ExecuteStep {
  args: Record<string, unknown>;
  delayMs: number;
  label: string;
}

interface HierarchyFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface HierarchyNode {
  className: string;
  path: string;
  frame: HierarchyFrame;
  depth?: number;
  subviews: HierarchyNode[];
}

interface MeshEntry {
  mesh: THREE.Mesh<THREE.PlaneGeometry, THREE.MeshBasicMaterial>;
  wireframe: THREE.LineSegments<THREE.EdgesGeometry, THREE.LineBasicMaterial>;
  node: HierarchyNode;
  absX: number;
  absY: number;
  frameW: number;
  frameH: number;
  isLeaf: boolean;
}

interface CameraAnimation {
  start: number;
  duration: number;
  from: { pos: THREE.Vector3; target: THREE.Vector3 };
  to: { pos: THREE.Vector3; target: THREE.Vector3 };
}

const MOVE_THRESHOLD = 10;
const DOUBLE_TAP_MS = 300;
const TAP_MAX_MS = 500;
const TYPE_DEBOUNCE = 150;
const MAX_EXECUTE_STEPS = 200;
const SCENE_SCALE = 0.5;
const SCENE_LAYER_SPACING = 24;
const EDGE_COLOR = 0x4ba8c7;
const EDGE_COLOR_HIGHLIGHT = 0x38bdf8;
const PANEL_COLOR = 0x1e293b;
const PANEL_OPACITY = 0.1;
const EDGE_OPACITY = 0.5;
const SCENE_BG = 0x0f1724;

function main(): void {
  const vscode = acquireVsCodeApi();
  const rootEl = requireElement<HTMLDivElement>("root");
  const paneResizerEl = requireElement<HTMLDivElement>("pane-resizer");
  const eventsPaneEl = requireElement<HTMLElement>("events-pane");
  const eventsResizerEl = requireElement<HTMLDivElement>("events-resizer");
  const maxEntries = parseMaxEntries(eventsPaneEl.dataset.maxEntries);

  const img = requireElement<HTMLImageElement>("screenshot");
  const scene3dEl = requireElement<HTMLDivElement>("scene-3d");
  const overlay = requireElement<HTMLDivElement>("overlay");
  const interactLayer = requireElement<HTMLDivElement>("interact-layer");
  const toastEl = requireElement<HTMLDivElement>("toast");
  const kbdIndicator = requireElement<HTMLDivElement>("kbd-indicator");
  const streamMetaEl = requireElement<HTMLDivElement>("stream-meta");
  const targetBadgeEl = requireElement<HTMLDivElement>("target-badge");
  const threeMetaEl = requireElement<HTMLDivElement>("three-meta");
  const streamToggleEl = requireElement<HTMLButtonElement>("stream-toggle");
  const previewChangesBtn = requireElement<HTMLButtonElement>("preview-changes");
  const fpsEl = requireElement<HTMLDivElement>("fps");
  const modeThreeBtn = requireElement<HTMLButtonElement>("mode-3d");
  const modeTouchBtn = requireElement<HTMLButtonElement>("mode-touch");
  const threeFitBtn = requireElement<HTMLButtonElement>("three-fit");
  const threeFocusBtn = requireElement<HTMLButtonElement>("three-focus");
  const threeTopBtn = requireElement<HTMLButtonElement>("three-top");
  const threeFrontBtn = requireElement<HTMLButtonElement>("three-front");
  const threeRefreshBtn = requireElement<HTMLButtonElement>("three-refresh");

  const tabLogsBtn = requireElement<HTMLButtonElement>("tab-logs");
  const tabNetworkBtn = requireElement<HTMLButtonElement>("tab-network");
  const searchEl = requireElement<HTMLInputElement>("search");
  const autoScrollBtn = requireElement<HTMLButtonElement>("auto-scroll");
  const execRecordBtn = requireElement<HTMLButtonElement>("exec-record");
  const execStopBtn = requireElement<HTMLButtonElement>("exec-stop");
  const execPlayBtn = requireElement<HTMLButtonElement>("exec-play");
  const execClearBtn = requireElement<HTMLButtonElement>("exec-clear");
  const execMetaEl = requireElement<HTMLDivElement>("execute-meta");
  const statusEl = requireElement<HTMLDivElement>("events-status");
  const logsListEl = requireElement<HTMLDivElement>("logs-list");
  const networkListEl = requireElement<HTMLDivElement>("network-list");
  const networkDetailEl = requireElement<HTMLDivElement>("network-detail");
  const networkDetailBodyEl = requireElement<HTMLPreElement>("network-detail-body");
  const stackedLayoutQuery = window.matchMedia("(max-width: 980px)");

  let frameCount = 0;
  let lastFpsTime = performance.now();
  let toastTimer: number | null = null;

  let mouseState: MouseState | null = null;
  let lastTapTime = 0;
  let lastTapCoord: { x: number; y: number } | null = null;
  let doubleTapTimer: number | null = null;

  let typeBuffer = "";
  let typeTimer: number | null = null;

  let nextInteractId = 0;
  const pendingInteractions = new Set<number>();
  const interactionWaiters = new Map<number, (result: { text?: string; error?: string }) => void>();
  let lastTargetBadge = "target: --";
  let targetOutlineEl: HTMLDivElement | null = null;
  let targetOutlineTimer: number | null = null;
  let selectedNetworkRow: HTMLElement | null = null;
  let selectedNetworkEntry: Record<string, unknown> | null = null;
  let executeRecording = false;
  let executePlaying = false;
  let executeCurrentStep = 0;
  let lastRecordedAt = 0;
  let executeRunToken = 0;
  const executeSteps: ExecuteStep[] = [];
  let hierarchyRoot: HierarchyNode | null = null;
  let hierarchyTexture: THREE.Texture | null = null;
  let hierarchyTextureLoadToken = 0;
  let hierarchyErrorText: string | null = null;
  let hierarchyRetryTimer: number | null = null;
  let hierarchyEntries: MeshEntry[] = [];
  let hierarchyScreenWidth = 0;
  let hierarchyScreenHeight = 0;
  let selectedHierarchyPath: string | null = null;
  let threeRenderer: THREE.WebGLRenderer | null = null;
  let threeScene: THREE.Scene | null = null;
  let threeCamera: THREE.PerspectiveCamera | null = null;
  let threeControls: OrbitControls | null = null;
  let threeRaycaster: THREE.Raycaster | null = null;
  const threeMouse = new THREE.Vector2();
  let threeAnimId: number | null = null;
  let threeResizeObs: ResizeObserver | null = null;
  let threeCameraAnim: CameraAnimation | null = null;
  let resizingEventsPane = false;
  let resizingSidePane = false;

  let uiState: UiState = {
    connectionState: "connecting",
    hasFrame: false,
    hasHierarchy: false,
    deviceScale: 0.5,
    streamPaused: false,
    streamMode: "idle",
    previewMode: "three",
    targetFps: 0,
    activeTab: "logs",
    autoScroll: true,
    searchText: "",
    logCount: 0,
    networkCount: 0,
  };

  const reduceUiState = (state: UiState, action: UiAction): UiState => {
    switch (action.type) {
      case "connectionState":
        return { ...state, connectionState: action.state };
      case "frameReceived":
        return { ...state, hasFrame: true };
      case "hierarchyUpdated":
        return { ...state, hasHierarchy: action.hasHierarchy };
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
      case "setPreviewMode":
        return { ...state, previewMode: action.mode };
      case "setActiveTab":
        return { ...state, activeTab: action.tab };
      case "toggleAutoScroll":
        return { ...state, autoScroll: !state.autoScroll };
      case "setSearchText":
        return { ...state, searchText: action.text };
      case "setLogCount":
        return { ...state, logCount: action.count };
      case "setNetworkCount":
        return { ...state, networkCount: action.count };
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
    } else if (uiState.previewMode === "three" && uiState.hasHierarchy) {
      overlay.classList.add("hidden");
    } else if (uiState.previewMode === "touch" && uiState.hasFrame) {
      overlay.classList.add("hidden");
    } else {
      overlay.textContent = uiState.previewMode === "three"
        ? hierarchyErrorText
          ? `Hierarchy unavailable: ${hierarchyErrorText}`
          : "Connected — waiting for hierarchy..."
        : "Connected — waiting for first frame...";
      overlay.classList.remove("hidden");
    }

    modeThreeBtn.classList.toggle("active", uiState.previewMode === "three");
    modeTouchBtn.classList.toggle("active", uiState.previewMode === "touch");
    scene3dEl.classList.toggle("hidden", uiState.previewMode !== "three");
    interactLayer.classList.toggle("touch-enabled", uiState.previewMode === "touch");
    interactLayer.style.pointerEvents = uiState.previewMode === "touch" ? "auto" : "none";
    img.classList.toggle("touch-visible", uiState.previewMode === "touch");
    img.classList.toggle("touch-hidden", uiState.previewMode !== "touch");
    if (uiState.previewMode !== "touch") {
      kbdIndicator.classList.remove("active");
      threeMetaEl.classList.remove("hidden");
    } else {
      threeMetaEl.classList.add("hidden");
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
    threeFocusBtn.disabled = selectedHierarchyPath === null;

    tabLogsBtn.classList.toggle("active", uiState.activeTab === "logs");
    tabNetworkBtn.classList.toggle("active", uiState.activeTab === "network");
    logsListEl.classList.toggle("hidden", uiState.activeTab !== "logs");
    networkListEl.classList.toggle("hidden", uiState.activeTab !== "network");

    autoScrollBtn.classList.toggle("active", uiState.autoScroll);
    networkDetailEl.classList.toggle("hidden", uiState.activeTab !== "network");

    updateEventsStatus();
    renderExecuteState();
  };

  const updateEventsStatus = (): void => {
    if (uiState.connectionState === "disconnected") {
      statusEl.textContent = "Disconnected — reconnecting...";
      return;
    }
    if (uiState.connectionState === "connecting") {
      statusEl.textContent = "Connecting...";
      return;
    }

    const activeList = uiState.activeTab === "logs" ? logsListEl : networkListEl;
    const visible = activeList.querySelectorAll(".entry:not(.hidden)").length;
    const total = uiState.activeTab === "logs" ? uiState.logCount : uiState.networkCount;
    statusEl.textContent = `${uiState.activeTab}: ${visible} / ${total} • logs ${uiState.logCount} • net ${uiState.networkCount}`;
  };

  const renderExecuteState = (): void => {
    execRecordBtn.classList.toggle("active", executeRecording);
    execRecordBtn.disabled = executePlaying;

    execStopBtn.disabled = !executeRecording && !executePlaying;

    execPlayBtn.classList.toggle("active", executePlaying);
    execPlayBtn.disabled = executePlaying || executeSteps.length === 0;

    execClearBtn.disabled = executePlaying || executeSteps.length === 0;

    if (executePlaying) {
      execMetaEl.textContent = `running: ${executeCurrentStep}/${executeSteps.length}`;
      return;
    }
    if (executeRecording) {
      execMetaEl.textContent = `recording • steps: ${executeSteps.length}`;
      return;
    }
    execMetaEl.textContent = `steps: ${executeSteps.length}`;
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

  const requestHierarchy = (): void => {
    if (hierarchyRetryTimer !== null) {
      window.clearTimeout(hierarchyRetryTimer);
      hierarchyRetryTimer = null;
    }
    send({ type: "requestHierarchy" });
  };

  const parseHierarchyFrame = (value: unknown): HierarchyFrame | null => {
    if (!isRecord(value)) {
      return null;
    }

    const x = typeof value.x === "number" ? value.x : NaN;
    const y = typeof value.y === "number" ? value.y : NaN;
    const width = typeof value.width === "number" ? value.width : NaN;
    const height = typeof value.height === "number" ? value.height : NaN;
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) || !Number.isFinite(height)) {
      return null;
    }
    return { x, y, width, height };
  };

  const parseHierarchyNode = (
    value: unknown,
    fallbackPath: string,
    depth: number
  ): HierarchyNode | null => {
    if (!isRecord(value)) {
      return null;
    }

    const className = typeof value.className === "string" ? value.className : "";
    const frame = parseHierarchyFrame(value.frame);
    if (!className || !frame) {
      return null;
    }

    const explicitPath = typeof value.path === "string" ? value.path : "";
    const path = explicitPath || fallbackPath;
    const nodeDepth = typeof value.depth === "number" && Number.isFinite(value.depth)
      ? value.depth
      : depth;
    const rawSubviews = Array.isArray(value.subviews) ? value.subviews : [];
    const subviews: HierarchyNode[] = [];

    for (let i = 0; i < rawSubviews.length; i++) {
      const childFallback = path === "root" ? `${i}` : `${path}.${i}`;
      const child = parseHierarchyNode(rawSubviews[i], childFallback, nodeDepth + 1);
      if (child) {
        subviews.push(child);
      }
    }

    return {
      className,
      path,
      frame,
      depth: nodeDepth,
      subviews,
    };
  };

  const setThreeMeta = (text: string): void => {
    threeMetaEl.textContent = text;
  };

  const applyTextureUv = (entry: MeshEntry): void => {
    if (!hierarchyTexture || hierarchyScreenWidth <= 0 || hierarchyScreenHeight <= 0) {
      return;
    }

    const geometry = entry.mesh.geometry;
    const uvAttr = geometry.attributes.uv;
    const uMin = entry.absX / hierarchyScreenWidth;
    const uMax = (entry.absX + entry.frameW) / hierarchyScreenWidth;
    const vMax = 1 - entry.absY / hierarchyScreenHeight;
    const vMin = 1 - (entry.absY + entry.frameH) / hierarchyScreenHeight;

    uvAttr.setXY(0, uMin, vMax);
    uvAttr.setXY(1, uMax, vMax);
    uvAttr.setXY(2, uMin, vMin);
    uvAttr.setXY(3, uMax, vMin);
    uvAttr.needsUpdate = true;
  };

  const applyHierarchyTextureToEntries = (): void => {
    if (!hierarchyTexture) {
      return;
    }

    for (const entry of hierarchyEntries) {
      if (!entry.isLeaf) {
        continue;
      }
      applyTextureUv(entry);
      entry.mesh.material.map = hierarchyTexture;
      entry.mesh.material.color.setHex(0xffffff);
      entry.mesh.material.opacity = 0.94;
      entry.mesh.material.needsUpdate = true;
      entry.wireframe.material.opacity = 0.22;
    }
  };

  const clearHierarchyEntries = (): void => {
    if (!threeScene) {
      hierarchyEntries = [];
      return;
    }

    for (const entry of hierarchyEntries) {
      threeScene.remove(entry.mesh);
      threeScene.remove(entry.wireframe);
      entry.mesh.geometry.dispose();
      entry.mesh.material.dispose();
      entry.wireframe.geometry.dispose();
      entry.wireframe.material.dispose();
    }
    hierarchyEntries = [];
  };

  const buildHierarchyMeshes = (
    node: HierarchyNode,
    offsetX = 0,
    offsetY = 0
  ): void => {
    if (!threeScene) {
      return;
    }

    const frame = node.frame;
    if (frame.width < 1 || frame.height < 1) {
      for (const child of node.subviews) {
        buildHierarchyMeshes(child, offsetX + frame.x, offsetY + frame.y);
      }
      return;
    }

    const depthValue = typeof node.depth === "number" ? node.depth : 0;
    const absX = offsetX + frame.x;
    const absY = offsetY + frame.y;
    const isLeaf = node.subviews.length === 0;
    const width = frame.width * SCENE_SCALE;
    const height = frame.height * SCENE_SCALE;
    const x = (absX + frame.width / 2) * SCENE_SCALE;
    const z = (absY + frame.height / 2) * SCENE_SCALE;
    const y = depthValue * SCENE_LAYER_SPACING;

    const geometry = new THREE.PlaneGeometry(width, height);
    const material = new THREE.MeshBasicMaterial({
      color: PANEL_COLOR,
      transparent: true,
      opacity: PANEL_OPACITY,
      side: THREE.DoubleSide,
      depthWrite: false,
    });

    if (isLeaf && hierarchyTexture && hierarchyScreenWidth > 0 && hierarchyScreenHeight > 0) {
      const uvAttr = geometry.attributes.uv;
      const uMin = absX / hierarchyScreenWidth;
      const uMax = (absX + frame.width) / hierarchyScreenWidth;
      const vMax = 1 - absY / hierarchyScreenHeight;
      const vMin = 1 - (absY + frame.height) / hierarchyScreenHeight;
      uvAttr.setXY(0, uMin, vMax);
      uvAttr.setXY(1, uMax, vMax);
      uvAttr.setXY(2, uMin, vMin);
      uvAttr.setXY(3, uMax, vMin);
      uvAttr.needsUpdate = true;
      material.map = hierarchyTexture;
      material.color.setHex(0xffffff);
      material.opacity = 0.94;
      material.needsUpdate = true;
    }

    const mesh = new THREE.Mesh(geometry, material);
    mesh.rotation.x = -Math.PI / 2;
    mesh.position.set(x, y, z);
    mesh.renderOrder = depthValue;
    threeScene.add(mesh);

    const edgesGeo = new THREE.EdgesGeometry(geometry);
    const edgesMat = new THREE.LineBasicMaterial({
      color: EDGE_COLOR,
      transparent: true,
      opacity: isLeaf && hierarchyTexture ? 0.22 : EDGE_OPACITY,
    });
    const wireframe = new THREE.LineSegments(edgesGeo, edgesMat);
    wireframe.rotation.x = -Math.PI / 2;
    wireframe.position.copy(mesh.position);
    wireframe.position.y += 0.08;
    wireframe.renderOrder = depthValue + 0.5;
    threeScene.add(wireframe);

    hierarchyEntries.push({
      mesh,
      wireframe,
      node,
      absX,
      absY,
      frameW: frame.width,
      frameH: frame.height,
      isLeaf,
    });

    for (const child of node.subviews) {
      buildHierarchyMeshes(child, absX, absY);
    }
  };

  const animateThreeCamera = (
    targetPos: THREE.Vector3,
    targetLookAt: THREE.Vector3,
    duration = 520
  ): void => {
    if (!threeCamera || !threeControls) {
      return;
    }

    threeCameraAnim = {
      start: performance.now(),
      duration,
      from: {
        pos: threeCamera.position.clone(),
        target: threeControls.target.clone(),
      },
      to: {
        pos: targetPos.clone(),
        target: targetLookAt.clone(),
      },
    };
  };

  const fitAll3D = (): void => {
    if (!threeCamera || !threeControls || hierarchyEntries.length === 0) {
      return;
    }

    const box = new THREE.Box3();
    for (const entry of hierarchyEntries) {
      box.expandByObject(entry.mesh);
    }
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.y, size.z, 1);
    const targetPos = new THREE.Vector3(
      center.x + maxDim * 0.62,
      center.y + maxDim * 0.55,
      center.z + maxDim * 0.82
    );
    animateThreeCamera(targetPos, center);
  };

  const focusOnHierarchyEntry = (entry: MeshEntry): void => {
    if (!threeCamera || !threeControls) {
      return;
    }
    const pos = entry.mesh.position;
    entry.mesh.geometry.computeBoundingBox();
    const bbox = entry.mesh.geometry.boundingBox;
    const maxDim = bbox ? Math.max(bbox.max.x - bbox.min.x, bbox.max.y - bbox.min.y, 50) : 50;
    const targetPos = new THREE.Vector3(
      pos.x + maxDim * 0.45,
      pos.y + maxDim * 0.9,
      pos.z + maxDim * 0.65
    );
    animateThreeCamera(targetPos, pos.clone(), 420);
  };

  const viewTop3D = (): void => {
    if (!threeCamera || !threeControls || hierarchyEntries.length === 0) {
      return;
    }

    const box = new THREE.Box3();
    for (const entry of hierarchyEntries) {
      box.expandByObject(entry.mesh);
    }
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.z, 1);
    const targetPos = new THREE.Vector3(center.x, center.y + maxDim * 1.6, center.z + 1);
    animateThreeCamera(targetPos, center);
  };

  const viewFront3D = (): void => {
    if (!threeCamera || !threeControls || hierarchyEntries.length === 0) {
      return;
    }

    const box = new THREE.Box3();
    for (const entry of hierarchyEntries) {
      box.expandByObject(entry.mesh);
    }
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    const maxDim = Math.max(size.x, size.y, 1);
    const targetPos = new THREE.Vector3(center.x, center.y, center.z + maxDim * 1.6);
    animateThreeCamera(targetPos, center);
  };

  const selectHierarchyEntry = (entry: MeshEntry | null, focus: boolean): void => {
    for (const item of hierarchyEntries) {
      const hasTex = Boolean(item.mesh.material.map);
      item.mesh.material.color.setHex(hasTex ? 0xffffff : PANEL_COLOR);
      item.mesh.material.opacity = hasTex ? 0.94 : PANEL_OPACITY;
      item.mesh.material.needsUpdate = true;
      item.wireframe.material.color.setHex(EDGE_COLOR);
      item.wireframe.material.opacity = hasTex ? 0.22 : EDGE_OPACITY;
      item.wireframe.material.needsUpdate = true;
    }

    if (!entry) {
      selectedHierarchyPath = null;
      setThreeMeta(`3D: ${hierarchyEntries.length} layer(s)`);
      renderUiState();
      return;
    }

    selectedHierarchyPath = entry.node.path;
    const hasTex = Boolean(entry.mesh.material.map);
    if (hasTex) {
      entry.mesh.material.opacity = 1;
    } else {
      entry.mesh.material.color.setHex(EDGE_COLOR_HIGHLIGHT);
      entry.mesh.material.opacity = 0.2;
    }
    entry.mesh.material.needsUpdate = true;
    entry.wireframe.material.color.setHex(EDGE_COLOR_HIGHLIGHT);
    entry.wireframe.material.opacity = 1;
    entry.wireframe.material.needsUpdate = true;
    setThreeMeta(`3D: ${entry.node.className} • ${entry.node.path || "root"}`);
    if (focus) {
      focusOnHierarchyEntry(entry);
    }
    renderUiState();
  };

  const findEntryByPath = (path: string | null): MeshEntry | null => {
    if (!path) {
      return null;
    }
    return hierarchyEntries.find((entry) => entry.node.path === path) ?? null;
  };

  const raycastHierarchyEntry = (event: MouseEvent): MeshEntry | null => {
    if (!threeRenderer || !threeCamera || !threeRaycaster || hierarchyEntries.length === 0) {
      return null;
    }
    const rect = threeRenderer.domElement.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      return null;
    }
    threeMouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    threeMouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;
    threeRaycaster.setFromCamera(threeMouse, threeCamera);
    const intersects = threeRaycaster.intersectObjects(
      hierarchyEntries.map((entry) => entry.mesh),
      false
    );
    if (intersects.length === 0) {
      return null;
    }
    const hit = intersects[0]?.object;
    return hierarchyEntries.find((entry) => entry.mesh === hit) ?? null;
  };

  let threePointerDownX = 0;
  let threePointerDownY = 0;
  let threeDragged = false;

  const onThreePointerDown = (event: PointerEvent): void => {
    if (event.button !== 0 || uiState.previewMode !== "three") {
      return;
    }
    threePointerDownX = event.clientX;
    threePointerDownY = event.clientY;
    threeDragged = false;
  };

  const onThreePointerUp = (event: PointerEvent): void => {
    if (event.button !== 0 || uiState.previewMode !== "three") {
      return;
    }
    threeDragged = Math.hypot(event.clientX - threePointerDownX, event.clientY - threePointerDownY) > 4;
  };

  const onThreeClick = (event: MouseEvent): void => {
    if (uiState.previewMode !== "three") {
      return;
    }
    if (threeDragged) {
      threeDragged = false;
      return;
    }
    const entry = raycastHierarchyEntry(event);
    selectHierarchyEntry(entry, false);
  };

  const onThreeDoubleClick = (event: MouseEvent): void => {
    if (uiState.previewMode !== "three") {
      return;
    }
    if (threeDragged) {
      threeDragged = false;
      return;
    }
    const entry = raycastHierarchyEntry(event);
    if (entry) {
      selectHierarchyEntry(entry, true);
    } else {
      fitAll3D();
    }
  };

  const renderThree = (): void => {
    threeAnimId = window.requestAnimationFrame(renderThree);
    if (!threeRenderer || !threeScene || !threeCamera || !threeControls) {
      return;
    }

    if (threeCameraAnim) {
      const elapsed = performance.now() - threeCameraAnim.start;
      let t = Math.min(elapsed / threeCameraAnim.duration, 1);
      t = 1 - Math.pow(1 - t, 3);
      threeCamera.position.lerpVectors(threeCameraAnim.from.pos, threeCameraAnim.to.pos, t);
      threeControls.target.lerpVectors(threeCameraAnim.from.target, threeCameraAnim.to.target, t);
      if (t >= 1) {
        threeCameraAnim = null;
      }
    }

    threeControls.update();
    threeRenderer.render(threeScene, threeCamera);
  };

  const onThreeResize = (): void => {
    if (!threeRenderer || !threeCamera) {
      return;
    }
    const width = scene3dEl.clientWidth;
    const height = scene3dEl.clientHeight;
    if (width <= 0 || height <= 0) {
      return;
    }
    threeRenderer.setSize(width, height);
    threeCamera.aspect = width / height;
    threeCamera.updateProjectionMatrix();
  };

  const initThree = (): void => {
    if (threeRenderer) {
      return;
    }

    const width = scene3dEl.clientWidth;
    const height = scene3dEl.clientHeight;
    if (width <= 0 || height <= 0) {
      return;
    }

    threeRenderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    threeRenderer.setSize(width, height);
    threeRenderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    threeRenderer.setClearColor(SCENE_BG, 1);
    scene3dEl.replaceChildren(threeRenderer.domElement);

    threeScene = new THREE.Scene();
    threeCamera = new THREE.PerspectiveCamera(40, width / height, 1, 8000);
    threeCamera.position.set(180, 280, 500);

    threeControls = new OrbitControls(threeCamera, threeRenderer.domElement);
    threeControls.enableDamping = true;
    threeControls.dampingFactor = 0.08;
    threeControls.minDistance = 50;
    threeControls.maxDistance = 3200;
    threeControls.mouseButtons = {
      LEFT: THREE.MOUSE.PAN,
      MIDDLE: THREE.MOUSE.DOLLY,
      RIGHT: THREE.MOUSE.ROTATE,
    };
    threeControls.screenSpacePanning = true;

    threeRaycaster = new THREE.Raycaster();
    threeRenderer.domElement.addEventListener("pointerdown", onThreePointerDown, { passive: true });
    threeRenderer.domElement.addEventListener("pointerup", onThreePointerUp, { passive: true });
    threeRenderer.domElement.addEventListener("click", onThreeClick);
    threeRenderer.domElement.addEventListener("dblclick", onThreeDoubleClick);

    threeResizeObs = new ResizeObserver(() => {
      onThreeResize();
    });
    threeResizeObs.observe(scene3dEl);

    renderThree();
  };

  const disposeThree = (): void => {
    clearHierarchyEntries();
    if (hierarchyRetryTimer !== null) {
      window.clearTimeout(hierarchyRetryTimer);
      hierarchyRetryTimer = null;
    }
    if (threeResizeObs) {
      threeResizeObs.disconnect();
      threeResizeObs = null;
    }
    if (threeAnimId !== null) {
      window.cancelAnimationFrame(threeAnimId);
      threeAnimId = null;
    }
    if (threeRenderer) {
      threeRenderer.domElement.removeEventListener("pointerdown", onThreePointerDown);
      threeRenderer.domElement.removeEventListener("pointerup", onThreePointerUp);
      threeRenderer.domElement.removeEventListener("click", onThreeClick);
      threeRenderer.domElement.removeEventListener("dblclick", onThreeDoubleClick);
      threeRenderer.dispose();
      threeRenderer.domElement.remove();
    }
    if (threeControls) {
      threeControls.dispose();
    }
    threeScene = null;
    threeCamera = null;
    threeControls = null;
    threeRaycaster = null;
    threeRenderer = null;
    threeCameraAnim = null;
    if (hierarchyTexture) {
      hierarchyTexture.dispose();
      hierarchyTexture = null;
    }
  };

  const rebuildHierarchyScene = (): void => {
    if (!hierarchyRoot) {
      clearHierarchyEntries();
      setThreeMeta("3D: no hierarchy");
      return;
    }

    initThree();
    if (!threeScene) {
      return;
    }

    clearHierarchyEntries();
    hierarchyScreenWidth = hierarchyRoot.frame.width;
    hierarchyScreenHeight = hierarchyRoot.frame.height;
    buildHierarchyMeshes(hierarchyRoot, 0, 0);
    setThreeMeta(`3D: ${hierarchyEntries.length} layer(s)`);

    const selected = findEntryByPath(selectedHierarchyPath);
    if (selected) {
      selectHierarchyEntry(selected, false);
    } else {
      fitAll3D();
    }
  };

  const updateHierarchyTexture = (base64: string): void => {
    const loadToken = ++hierarchyTextureLoadToken;
    const image = new Image();
    image.onload = () => {
      if (loadToken !== hierarchyTextureLoadToken) {
        return;
      }
      if (hierarchyTexture) {
        hierarchyTexture.dispose();
      }
      hierarchyTexture = new THREE.Texture(image);
      hierarchyTexture.needsUpdate = true;
      hierarchyTexture.colorSpace = THREE.SRGBColorSpace;
      applyHierarchyTextureToEntries();
      const selected = findEntryByPath(selectedHierarchyPath);
      if (selected) {
        selectHierarchyEntry(selected, false);
      }
    };
    image.src = `data:image/jpeg;base64,${base64}`;
  };

  const renderNetworkDetail = (): void => {
    if (!selectedNetworkEntry) {
      networkDetailBodyEl.textContent = "Select a network row to inspect details.";
      return;
    }
    networkDetailBodyEl.textContent = safePrettyJson(selectedNetworkEntry);
  };

  const selectNetworkEntry = (entry: Record<string, unknown>, row: HTMLElement): void => {
    if (selectedNetworkRow) {
      selectedNetworkRow.classList.remove("selected");
    }
    selectedNetworkRow = row;
    selectedNetworkRow.classList.add("selected");
    selectedNetworkEntry = entry;
    renderNetworkDetail();
  };

  const send = (message: OutboundMessage): void => {
    vscode.postMessage(message);
  };

  const sendInteraction = (
    args: Record<string, unknown>,
    pendingText: string,
    source: "user" | "replay" = "user"
  ): number => {
    const id = ++nextInteractId;
    showToast(pendingText);
    send({ type: "interact", id, args });
    pendingInteractions.add(id);

    if (executeRecording && source === "user") {
      const now = Date.now();
      const delayMs = executeSteps.length === 0 ? 0 : Math.min(5000, Math.max(0, now - lastRecordedAt));
      lastRecordedAt = now;
      executeSteps.push({
        args: cloneArgs(args),
        delayMs,
        label: describeStep(args),
      });

      if (executeSteps.length > MAX_EXECUTE_STEPS) {
        executeSteps.shift();
      }
      renderExecuteState();
    }

    return id;
  };

  const waitForInteractionResult = (id: number, timeoutMs: number): Promise<{ ok: boolean; error?: string }> => {
    return new Promise((resolve) => {
      const timer = window.setTimeout(() => {
        interactionWaiters.delete(id);
        resolve({ ok: false, error: "timeout waiting for interactResult" });
      }, timeoutMs);

      interactionWaiters.set(id, (result) => {
        window.clearTimeout(timer);
        resolve({ ok: !result.error, error: result.error });
      });
    });
  };

  const delay = (ms: number): Promise<void> =>
    new Promise((resolve) => {
      window.setTimeout(resolve, ms);
    });

  const syncDragBodyStyles = (): void => {
    if (resizingSidePane || resizingEventsPane) {
      document.body.style.userSelect = "none";
      document.body.style.cursor = resizingSidePane ? "col-resize" : "row-resize";
      return;
    }

    document.body.style.removeProperty("user-select");
    document.body.style.removeProperty("cursor");
  };

  const clampSidePaneWidth = (candidate: number): number => {
    const rootRect = rootEl.getBoundingClientRect();
    const minEventsWidth = 280;
    const minPreviewWidth = 320;
    const splitterWidth = 8;
    const maxEventsWidth = Math.max(
      minEventsWidth,
      Math.floor(rootRect.width - minPreviewWidth - splitterWidth)
    );
    return Math.round(Math.min(maxEventsWidth, Math.max(minEventsWidth, candidate)));
  };

  const applySidePaneWidth = (candidate: number): void => {
    rootEl.style.setProperty("--side-pane-width", `${clampSidePaneWidth(candidate)}px`);
  };

  const syncSidePaneWidth = (): void => {
    if (stackedLayoutQuery.matches) {
      return;
    }

    const styleValue = Number.parseFloat(
      getComputedStyle(rootEl).getPropertyValue("--side-pane-width")
    );
    const currentWidth = Number.isFinite(styleValue) && styleValue > 0
      ? styleValue
      : eventsPaneEl.getBoundingClientRect().width;

    applySidePaneWidth(currentWidth);
  };

  const clampEventsPaneHeight = (candidate: number): number => {
    const rootRect = rootEl.getBoundingClientRect();
    const minHeight = 170;
    const minPreviewHeight = 300;
    const maxHeight = Math.max(minHeight, Math.floor(rootRect.height - minPreviewHeight));
    return Math.round(Math.min(maxHeight, Math.max(minHeight, candidate)));
  };

  const applyEventsPaneHeight = (candidate: number): void => {
    rootEl.style.setProperty("--stacked-events-height", `${clampEventsPaneHeight(candidate)}px`);
  };

  const syncEventsPaneHeight = (): void => {
    if (!stackedLayoutQuery.matches) {
      return;
    }

    const styleValue = Number.parseFloat(
      getComputedStyle(rootEl).getPropertyValue("--stacked-events-height")
    );
    const currentHeight = Number.isFinite(styleValue) && styleValue > 0
      ? styleValue
      : eventsPaneEl.getBoundingClientRect().height;

    applyEventsPaneHeight(currentHeight);
  };

  const stopEventsPaneResize = (): void => {
    if (!resizingEventsPane) {
      return;
    }

    resizingEventsPane = false;
    syncDragBodyStyles();
  };

  const stopSidePaneResize = (): void => {
    if (!resizingSidePane) {
      return;
    }

    resizingSidePane = false;
    syncDragBodyStyles();
  };

  const stopExecute = (reason?: string): void => {
    executeRunToken++;
    const wasRunning = executePlaying;
    executePlaying = false;
    executeRecording = false;
    executeCurrentStep = 0;
    renderExecuteState();
    if (wasRunning && reason) {
      showToast(reason);
    }
  };

  const runExecute = async (): Promise<void> => {
    if (executePlaying || executeSteps.length === 0) {
      return;
    }

    executeRecording = false;
    executePlaying = true;
    executeCurrentStep = 0;
    const runToken = ++executeRunToken;
    renderExecuteState();

    try {
      for (let i = 0; i < executeSteps.length; i++) {
        if (runToken !== executeRunToken) {
          return;
        }

        const step = executeSteps[i];
        executeCurrentStep = i + 1;
        renderExecuteState();

        if (step.delayMs > 0) {
          await delay(step.delayMs);
        }
        if (runToken !== executeRunToken) {
          return;
        }

        const id = sendInteraction(
          cloneArgs(step.args),
          `Execute ${i + 1}/${executeSteps.length}: ${step.label}`,
          "replay"
        );

        const outcome = await waitForInteractionResult(id, 15000);
        if (runToken !== executeRunToken) {
          return;
        }
        if (!outcome.ok) {
          stopExecute(`Execute stopped at step ${i + 1}: ${outcome.error ?? "interaction failed"}`);
          return;
        }
      }

      stopExecute("Execute completed.");
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : String(error);
      stopExecute(`Execute error: ${msg}`);
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

  const applySearchFilters = (): void => {
    for (const list of [logsListEl, networkListEl]) {
      list.querySelectorAll<HTMLElement>(".entry").forEach((entry) => {
        const searchable = entry.dataset.search || "";
        const matches = !uiState.searchText || searchable.includes(uiState.searchText);
        entry.classList.toggle("hidden", !matches);
      });
    }
    updateEventsStatus();
  };

  const makeLogEntry = (entry: Record<string, unknown>): HTMLElement => {
    const level = normalizeLevel(entry.level);
    const source = toText(entry.source);
    const message = toText(entry.message);
    const timestamp = formatTime(toText(entry.timestamp));

    const row = document.createElement("div");
    row.className = `entry ${levelClass(level)}`;
    row.dataset.search = `${level} ${source} ${message}`.toLowerCase();

    const line1 = document.createElement("div");
    line1.innerHTML = `<span class="title">${escapeHtml(level.toUpperCase())}</span><span class="meta">${escapeHtml(timestamp)} • ${escapeHtml(source)}</span>`;

    const line2 = document.createElement("div");
    line2.textContent = message;

    row.appendChild(line1);
    row.appendChild(line2);
    return row;
  };

  const makeNetworkEntry = (entry: Record<string, unknown>): HTMLElement => {
    const method = toText(entry.method || "GET").toUpperCase();
    const url = toText(entry.url);
    const statusRaw = entry.status;
    const status = typeof statusRaw === "number" ? statusRaw : NaN;
    const durationRaw = entry.duration_ms;
    const duration = typeof durationRaw === "number" ? durationRaw : NaN;
    const error = toText(entry.error);
    const timestamp = formatTime(toText(entry.timestamp));

    const row = document.createElement("div");
    const isError = error.length > 0 || (!Number.isNaN(status) && status >= 400);
    const cls = isError ? "error" : "";
    row.className = `entry ${cls}`.trim();
    row.dataset.search = `${method} ${url} ${status} ${error}`.toLowerCase();

    const statusLabel = Number.isNaN(status) ? "-" : String(status);
    const durationLabel = Number.isNaN(duration) ? "-" : `${Math.round(duration)} ms`;

    const line1 = document.createElement("div");
    line1.innerHTML = `<span class="title">${escapeHtml(method)}</span><span class="meta">${escapeHtml(statusLabel)} • ${escapeHtml(durationLabel)} • ${escapeHtml(timestamp)}</span>`;

    const line2 = document.createElement("div");
    line2.textContent = url;

    row.appendChild(line1);
    row.appendChild(line2);

    if (error) {
      const line3 = document.createElement("div");
      line3.textContent = error;
      row.appendChild(line3);
    }

    return row;
  };

  const appendEntry = (
    list: HTMLDivElement,
    row: HTMLElement,
    updateCount: (count: number) => void,
    getCount: () => number,
    isActive: () => boolean
  ): void => {
    list.appendChild(row);

    let nextCount = getCount() + 1;
    while (list.children.length > maxEntries) {
      if (list.firstChild) {
        list.removeChild(list.firstChild);
      }
      nextCount--;
    }

    if (uiState.autoScroll && isActive()) {
      list.scrollTop = list.scrollHeight;
    }

    updateCount(Math.max(0, nextCount));
    applySearchFilters();
  };

  paneResizerEl.addEventListener("pointerdown", (event) => {
    if (stackedLayoutQuery.matches || event.button !== 0) {
      return;
    }

    resizingSidePane = true;
    syncDragBodyStyles();
    paneResizerEl.setPointerCapture(event.pointerId);
    event.preventDefault();
  });

  paneResizerEl.addEventListener("pointermove", (event) => {
    if (!resizingSidePane || stackedLayoutQuery.matches) {
      return;
    }

    const rootRect = rootEl.getBoundingClientRect();
    const nextWidth = rootRect.right - event.clientX;
    applySidePaneWidth(nextWidth);
  });

  paneResizerEl.addEventListener("pointerup", () => {
    stopSidePaneResize();
  });

  paneResizerEl.addEventListener("pointercancel", () => {
    stopSidePaneResize();
  });

  paneResizerEl.addEventListener("lostpointercapture", () => {
    stopSidePaneResize();
  });

  eventsResizerEl.addEventListener("pointerdown", (event) => {
    if (!stackedLayoutQuery.matches || event.button !== 0) {
      return;
    }

    resizingEventsPane = true;
    syncDragBodyStyles();
    eventsResizerEl.setPointerCapture(event.pointerId);
    event.preventDefault();
  });

  eventsResizerEl.addEventListener("pointermove", (event) => {
    if (!resizingEventsPane || !stackedLayoutQuery.matches) {
      return;
    }

    const rootRect = rootEl.getBoundingClientRect();
    const nextHeight = rootRect.bottom - event.clientY;
    applyEventsPaneHeight(nextHeight);
  });

  eventsResizerEl.addEventListener("pointerup", () => {
    stopEventsPaneResize();
  });

  eventsResizerEl.addEventListener("pointercancel", () => {
    stopEventsPaneResize();
  });

  eventsResizerEl.addEventListener("lostpointercapture", () => {
    stopEventsPaneResize();
  });

  modeThreeBtn.addEventListener("click", () => {
    dispatchUi({ type: "setPreviewMode", mode: "three" });
    if (!uiState.hasHierarchy) {
      requestHierarchy();
    }
    initThree();
    renderUiState();
  });

  modeTouchBtn.addEventListener("click", () => {
    dispatchUi({ type: "setPreviewMode", mode: "touch" });
    renderUiState();
  });

  threeFitBtn.addEventListener("click", () => {
    fitAll3D();
  });

  threeFocusBtn.addEventListener("click", () => {
    const entry = findEntryByPath(selectedHierarchyPath);
    if (entry) {
      focusOnHierarchyEntry(entry);
    }
  });

  threeTopBtn.addEventListener("click", () => {
    viewTop3D();
  });

  threeFrontBtn.addEventListener("click", () => {
    viewFront3D();
  });

  threeRefreshBtn.addEventListener("click", () => {
    requestHierarchy();
    showToast("Refreshing hierarchy...");
  });

  streamToggleEl.addEventListener("click", () => {
    send(uiState.streamPaused ? { type: "resumeStream" } : { type: "pauseStream" });
  });

  previewChangesBtn.addEventListener("click", () => {
    send({ type: "previewChanges" });
    showToast("Running Preview Changes...");
  });

  tabLogsBtn.addEventListener("click", () => {
    dispatchUi({ type: "setActiveTab", tab: "logs" });
    applySearchFilters();
  });

  tabNetworkBtn.addEventListener("click", () => {
    dispatchUi({ type: "setActiveTab", tab: "network" });
    applySearchFilters();
  });

  autoScrollBtn.addEventListener("click", () => {
    dispatchUi({ type: "toggleAutoScroll" });
  });

  searchEl.addEventListener("input", () => {
    dispatchUi({ type: "setSearchText", text: searchEl.value.toLowerCase() });
    applySearchFilters();
  });

  execRecordBtn.addEventListener("click", () => {
    if (executePlaying) {
      return;
    }
    executeRecording = !executeRecording;
    if (executeRecording) {
      lastRecordedAt = Date.now();
      showToast("Execute recording started.");
    } else {
      showToast(`Execute recording stopped • ${executeSteps.length} step(s).`);
    }
    renderExecuteState();
  });

  execStopBtn.addEventListener("click", () => {
    if (executeRecording) {
      executeRecording = false;
      renderExecuteState();
      showToast(`Execute recording stopped • ${executeSteps.length} step(s).`);
      return;
    }
    if (executePlaying) {
      stopExecute("Execute stopped.");
    }
  });

  execPlayBtn.addEventListener("click", () => {
    void runExecute();
  });

  execClearBtn.addEventListener("click", () => {
    if (executePlaying) {
      return;
    }
    executeSteps.length = 0;
    executeCurrentStep = 0;
    renderExecuteState();
    showToast("Execute steps cleared.");
  });

  interactLayer.addEventListener("mousedown", (e) => {
    if (uiState.previewMode !== "touch") {
      return;
    }
    if (e.button !== 0) {
      return;
    }
    mouseState = { startX: e.clientX, startY: e.clientY, startTime: Date.now() };
    interactLayer.focus();
    e.preventDefault();
  });

  document.addEventListener("mouseup", (e) => {
    if (uiState.previewMode !== "touch") {
      mouseState = null;
      return;
    }
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
    if (uiState.previewMode !== "touch") {
      return;
    }
    e.preventDefault();
  });

  interactLayer.addEventListener("keydown", (e) => {
    if (uiState.previewMode !== "touch") {
      return;
    }
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
    if (uiState.previewMode !== "touch") {
      return;
    }
    kbdIndicator.classList.add("active");
  });

  interactLayer.addEventListener("blur", () => {
    if (uiState.previewMode !== "touch") {
      return;
    }
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
        updateHierarchyTexture(msg.data);
        frameCount++;
        updateFps();
        dispatchUi({ type: "frameReceived" });
        break;
      case "hierarchy": {
        const parsed = msg.hierarchy
          ? parseHierarchyNode(msg.hierarchy, "root", 0)
          : null;
        hierarchyRoot = parsed;
        hierarchyErrorText = parsed ? null : (msg.error ?? "unknown error");
        dispatchUi({ type: "hierarchyUpdated", hasHierarchy: parsed !== null });
        if (parsed) {
          initThree();
          rebuildHierarchyScene();
          if (hierarchyRetryTimer !== null) {
            window.clearTimeout(hierarchyRetryTimer);
            hierarchyRetryTimer = null;
          }
        } else {
          clearHierarchyEntries();
          selectedHierarchyPath = null;
          setThreeMeta(`3D: ${hierarchyErrorText}`);
          showToast(`3D hierarchy error: ${hierarchyErrorText}`);
          if (uiState.connectionState === "connected" && hierarchyRetryTimer === null) {
            hierarchyRetryTimer = window.setTimeout(() => {
              hierarchyRetryTimer = null;
              requestHierarchy();
            }, 1800);
          }
          renderUiState();
        }
        break;
      }
      case "connectionState":
        dispatchUi({ type: "connectionState", state: msg.state });
        if (msg.state === "connected") {
          requestHierarchy();
        }
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
        const waiter = interactionWaiters.get(msg.id);
        if (waiter) {
          interactionWaiters.delete(msg.id);
          waiter({ text: msg.text, error: msg.error });
        }
        if (msg.error) {
          showToast(`Error: ${msg.error}${meta}`);
        } else if (msg.text) {
          showToast(`${msg.text}${meta}`);
        }
        break;
      case "log": {
        const row = makeLogEntry(msg.entry);
        appendEntry(
          logsListEl,
          row,
          (count) => dispatchUi({ type: "setLogCount", count }),
          () => uiState.logCount,
          () => uiState.activeTab === "logs"
        );
        break;
      }
      case "bulkLogs":
        logsListEl.innerHTML = "";
        dispatchUi({ type: "setLogCount", count: 0 });
        msg.entries.forEach((entry) => {
          const row = makeLogEntry(entry);
          appendEntry(
            logsListEl,
            row,
            (count) => dispatchUi({ type: "setLogCount", count }),
            () => uiState.logCount,
            () => uiState.activeTab === "logs"
          );
        });
        break;
      case "network": {
        const row = makeNetworkEntry(msg.entry);
        row.addEventListener("click", () => {
          selectNetworkEntry(msg.entry, row);
        });
        appendEntry(
          networkListEl,
          row,
          (count) => dispatchUi({ type: "setNetworkCount", count }),
          () => uiState.networkCount,
          () => uiState.activeTab === "network"
        );
        if (selectedNetworkRow && !networkListEl.contains(selectedNetworkRow)) {
          selectedNetworkRow = null;
          selectedNetworkEntry = null;
          renderNetworkDetail();
        }
        break;
      }
      case "bulkNetwork":
        networkListEl.innerHTML = "";
        selectedNetworkRow = null;
        selectedNetworkEntry = null;
        renderNetworkDetail();
        dispatchUi({ type: "setNetworkCount", count: 0 });
        msg.entries.forEach((entry) => {
          const row = makeNetworkEntry(entry);
          row.addEventListener("click", () => {
            selectNetworkEntry(entry, row);
          });
          appendEntry(
            networkListEl,
            row,
            (count) => dispatchUi({ type: "setNetworkCount", count }),
            () => uiState.networkCount,
            () => uiState.activeTab === "network"
          );
        });
        break;
      default:
        assertNever(msg);
    }
  });

  window.addEventListener("beforeunload", () => {
    stopSidePaneResize();
    stopEventsPaneResize();
    disposeThree();
  });

  window.addEventListener("resize", () => {
    syncSidePaneWidth();
    syncEventsPaneHeight();
  });

  stackedLayoutQuery.addEventListener("change", () => {
    stopSidePaneResize();
    stopEventsPaneResize();
    syncSidePaneWidth();
    syncEventsPaneHeight();
  });

  initThree();
  syncSidePaneWidth();
  syncEventsPaneHeight();
  requestHierarchy();
  renderNetworkDetail();
  renderExecuteState();
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
    case "hierarchy":
      if (value.hierarchy === null || isRecord(value.hierarchy)) {
        return {
          type: "hierarchy",
          hierarchy: value.hierarchy ?? null,
          error: typeof value.error === "string" ? value.error : undefined,
        };
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
      if (typeof value.id === "number") {
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
      }
      return null;
    case "log":
      if (isRecord(value.entry)) {
        return { type: "log", entry: value.entry };
      }
      return null;
    case "bulkLogs":
      if (Array.isArray(value.entries) && value.entries.every((entry) => isRecord(entry))) {
        return { type: "bulkLogs", entries: value.entries as Record<string, unknown>[] };
      }
      return null;
    case "network":
      if (isRecord(value.entry)) {
        return { type: "network", entry: value.entry };
      }
      return null;
    case "bulkNetwork":
      if (Array.isArray(value.entries) && value.entries.every((entry) => isRecord(entry))) {
        return { type: "bulkNetwork", entries: value.entries as Record<string, unknown>[] };
      }
      return null;
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

function cloneArgs(args: Record<string, unknown>): Record<string, unknown> {
  try {
    return JSON.parse(JSON.stringify(args)) as Record<string, unknown>;
  } catch {
    return { ...args };
  }
}

function describeStep(args: Record<string, unknown>): string {
  const action = typeof args.action === "string" ? args.action : "interact";
  const identifier = typeof args.identifier === "string" ? args.identifier : "";
  const label = typeof args.label === "string" ? args.label : "";
  const path = typeof args.path === "string" ? args.path : "";
  const target = identifier || label || path;
  if (target) {
    return `${action} ${target}`;
  }

  const coord = isRecord(args.coordinate)
    && typeof args.coordinate.x === "number"
    && typeof args.coordinate.y === "number"
    ? `(${Math.round(args.coordinate.x)},${Math.round(args.coordinate.y)})`
    : "";
  return coord ? `${action} ${coord}` : action;
}

function safePrettyJson(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function shorten(text: string, maxLen: number): string {
  if (text.length <= maxLen) {
    return text;
  }
  return `${text.slice(0, maxLen - 1)}...`;
}

function parseMaxEntries(raw: string | undefined): number {
  if (!raw) {
    return 1000;
  }

  const parsed = Number.parseInt(raw, 10);
  if (Number.isNaN(parsed) || parsed <= 0) {
    return 1000;
  }

  return parsed;
}

function normalizeLevel(value: unknown): string {
  return toText(value).toLowerCase() || "debug";
}

function levelClass(level: string): string {
  if (level === "error" || level === "fault") {
    return "error";
  }
  if (level === "warning" || level === "warn") {
    return "warn";
  }
  return "";
}

function formatTime(iso: string): string {
  try {
    const date = new Date(iso);
    return date.toLocaleTimeString("en-US", {
      hour12: false,
      fractionalSecondDigits: 3,
    } as Intl.DateTimeFormatOptions);
  } catch {
    return iso;
  }
}

function toText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  return String(value ?? "");
}

function escapeHtml(input: string): string {
  return input
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireElement<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) {
    throw new Error(`Missing element #${id}`);
  }
  return el as T;
}

function assertNever(_: never): never {
  throw new Error("Unhandled message variant");
}

main();
