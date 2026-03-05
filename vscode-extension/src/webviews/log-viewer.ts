import type { ConnectionState } from "../types";

declare function acquireVsCodeApi(): {
  postMessage(message: unknown): void;
};

type ConnectionUiState = ConnectionState | "unknown";

type HostMessage =
  | { type: "log"; entry: Record<string, unknown> }
  | { type: "bulk"; entries: Record<string, unknown>[] }
  | { type: "connectionState"; state: ConnectionState };

type OutboundMessage =
  | { type: "pause" }
  | { type: "resume" }
  | { type: "clear" }
  | { type: "export" };

interface UiState {
  autoScroll: boolean;
  paused: boolean;
  activeLevel: string;
  searchText: string;
  entryCount: number;
  connectionState: ConnectionUiState;
}

type UiAction =
  | { type: "toggleAutoScroll" }
  | { type: "setPaused"; value: boolean }
  | { type: "setLevelFilter"; value: string }
  | { type: "setSearchText"; value: string }
  | { type: "setEntryCount"; value: number }
  | { type: "setConnectionState"; value: ConnectionUiState };

function main(): void {
  const vscode = acquireVsCodeApi();
  const logsEl = requireElement<HTMLDivElement>("logs");
  const statusEl = requireElement<HTMLDivElement>("status");
  const searchEl = requireElement<HTMLInputElement>("search");
  const btnAutoScroll = requireElement<HTMLButtonElement>("btnAutoScroll");
  const btnPause = requireElement<HTMLButtonElement>("btnPause");
  const maxEntries = parseMaxEntries(document.body.dataset.maxEntries);

  let uiState: UiState = {
    autoScroll: true,
    paused: false,
    activeLevel: "all",
    searchText: "",
    entryCount: 0,
    connectionState: "unknown",
  };

  const reduceUiState = (state: UiState, action: UiAction): UiState => {
    switch (action.type) {
      case "toggleAutoScroll":
        return { ...state, autoScroll: !state.autoScroll };
      case "setPaused":
        return { ...state, paused: action.value };
      case "setLevelFilter":
        return { ...state, activeLevel: action.value };
      case "setSearchText":
        return { ...state, searchText: action.value };
      case "setEntryCount":
        return { ...state, entryCount: action.value };
      case "setConnectionState":
        return { ...state, connectionState: action.value };
      default:
        return state;
    }
  };

  const dispatchUi = (action: UiAction, render = true): void => {
    uiState = reduceUiState(uiState, action);
    if (render) {
      renderUiState();
    }
  };

  const updateStatus = (): void => {
    const visible = logsEl.querySelectorAll(".log-entry:not(.hidden)").length;
    if (uiState.connectionState === "connected") {
      statusEl.textContent = `${visible} / ${uiState.entryCount} entries${uiState.paused ? " (paused)" : ""}`;
      return;
    }
    if (uiState.connectionState === "disconnected") {
      statusEl.textContent = "Disconnected — reconnecting...";
      return;
    }
    statusEl.textContent = "Connecting...";
  };

  const renderUiState = (): void => {
    btnAutoScroll.classList.toggle("active", uiState.autoScroll);
    btnPause.textContent = uiState.paused ? "Resume" : "Pause";
    btnPause.classList.toggle("active", uiState.paused);
    updateStatus();
  };

  document.querySelectorAll<HTMLElement>("[data-level]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll<HTMLElement>("[data-level]").forEach((b) => {
        b.classList.remove("active");
      });
      btn.classList.add("active");
      dispatchUi({ type: "setLevelFilter", value: btn.dataset.level || "all" });
      applyFilters();
    });
  });

  searchEl.addEventListener("input", () => {
    dispatchUi({ type: "setSearchText", value: searchEl.value.toLowerCase() });
    applyFilters();
  });

  btnAutoScroll.addEventListener("click", () => {
    dispatchUi({ type: "toggleAutoScroll" });
  });

  btnPause.addEventListener("click", () => {
    const nextPaused = !uiState.paused;
    dispatchUi({ type: "setPaused", value: nextPaused });
    post(nextPaused ? { type: "pause" } : { type: "resume" });
  });

  requireElement<HTMLButtonElement>("btnClear").addEventListener("click", () => {
    logsEl.innerHTML = "";
    dispatchUi({ type: "setEntryCount", value: 0 });
    post({ type: "clear" });
  });

  requireElement<HTMLButtonElement>("btnExport").addEventListener("click", () => {
    post({ type: "export" });
  });

  const post = (message: OutboundMessage): void => {
    vscode.postMessage(message);
  };

  const addEntry = (entry: Record<string, unknown>, render = true): void => {
    const level = normalizeLevel(entry.level);
    const displayLevel = toText(entry.level || level);
    const source = toText(entry.source);
    const message = toText(entry.message);
    const timestamp = toText(entry.timestamp);

    const div = document.createElement("div");
    div.className = `log-entry ${levelClass(level)}`;
    div.dataset.level = level;
    div.dataset.text = `${message} ${source}`.toLowerCase();

    const ts = document.createElement("span");
    ts.className = "timestamp";
    ts.textContent = `[${formatTime(timestamp)}]`;

    const src = document.createElement("span");
    src.className = "source";
    src.textContent = `[${source}]`;

    div.appendChild(ts);
    div.appendChild(document.createTextNode(` [${displayLevel.toUpperCase().padEnd(7)}] `));
    div.appendChild(src);
    div.appendChild(document.createTextNode(` ${message}`));

    applyFilterToEntry(div);
    logsEl.appendChild(div);

    let nextCount = uiState.entryCount + 1;
    while (logsEl.children.length > maxEntries) {
      if (logsEl.firstChild) {
        logsEl.removeChild(logsEl.firstChild);
      }
      nextCount--;
    }

    if (render && uiState.autoScroll) {
      logsEl.scrollTop = logsEl.scrollHeight;
    }

    dispatchUi({ type: "setEntryCount", value: Math.max(0, nextCount) }, render);
  };

  const applyFilterToEntry = (el: HTMLElement): void => {
    const level = el.dataset.level || "";
    const text = el.dataset.text || "";
    const activeLevel = uiState.activeLevel;

    const matchLevel =
      activeLevel === "all" ||
      level === activeLevel ||
      (activeLevel === "warning" && (level === "warning" || level === "warn")) ||
      (activeLevel === "error" && (level === "error" || level === "fault"));
    const matchSearch = !uiState.searchText || text.includes(uiState.searchText);

    el.classList.toggle("hidden", !(matchLevel && matchSearch));
  };

  const applyFilters = (): void => {
    logsEl.querySelectorAll<HTMLElement>(".log-entry").forEach(applyFilterToEntry);
    updateStatus();
  };

  window.addEventListener("message", (event: MessageEvent<unknown>) => {
    const msg = parseHostMessage(event.data);
    if (!msg) {
      return;
    }

    switch (msg.type) {
      case "log":
        addEntry(msg.entry);
        break;
      case "bulk":
        logsEl.innerHTML = "";
        dispatchUi({ type: "setEntryCount", value: 0 }, false);
        msg.entries.forEach((entry) => addEntry(entry, false));
        if (uiState.autoScroll) {
          logsEl.scrollTop = logsEl.scrollHeight;
        }
        updateStatus();
        break;
      case "connectionState":
        dispatchUi({ type: "setConnectionState", value: msg.state });
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
    case "log":
      if (isRecord(value.entry)) {
        return { type: "log", entry: value.entry };
      }
      return null;
    case "bulk":
      if (Array.isArray(value.entries) && value.entries.every((entry) => isRecord(entry))) {
        return { type: "bulk", entries: value.entries as Record<string, unknown>[] };
      }
      return null;
    case "connectionState":
      if (isConnectionState(value.state)) {
        return { type: "connectionState", state: value.state };
      }
      return null;
    default:
      return null;
  }
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

function isConnectionState(value: unknown): value is ConnectionState {
  return value === "disconnected" || value === "connecting" || value === "connected";
}

function toText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }
  return String(value ?? "");
}

function normalizeLevel(value: unknown): string {
  const normalized = toText(value).toLowerCase();
  return normalized || "debug";
}

function levelClass(level: string): string {
  if (level === "error" || level === "fault") {
    return "level-error";
  }
  if (level === "warning" || level === "warn") {
    return "level-warning";
  }
  if (level === "info" || level === "notice") {
    return "level-info";
  }
  return "level-debug";
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
