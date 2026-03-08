import * as vscode from "vscode";
import * as path from "path";
import { ApusClient } from "./apus-client";
import { ApplyIndicatorState, StatusBar } from "./status-bar";
import {
  buildFileIndexEntry,
  FileIndexEntry,
  FileIndexStore,
  IndexStore,
} from "./auto-apply/index-store";
import { LivePreviewPanel } from "./panels/live-preview-panel";
import { LogViewerPanel } from "./panels/log-viewer-panel";
import { InspectorPanel } from "./panels/inspector-panel";
import { registerPreviewChangesCommand } from "./preview-changes";
import {
  DEFAULT_WS_HOST,
  DEFAULT_WS_PORT,
  DEFAULT_RECONNECT_INTERVAL_MS,
} from "./constants";
import { extractToolResultText, isToolResultError } from "./mcp-tool-result";

let client: ApusClient;
let statusBar: StatusBar;
const DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS = 2000;
const DEFAULT_AUTO_PREVIEW_SCRIPT_PATH = "ExampleApp/build-and-run.sh --build";
const DEFAULT_AUTO_PREVIEW_FILE_GLOBS = [
  "ExampleApp/*.swift",
  "ExampleApp/**/*.swift",
  "Sources/*.swift",
  "Sources/**/*.swift",
  "Package.swift",
  "ExampleApp/project.yml",
  "ExampleApp/build-and-run.sh",
];
const DEFAULT_AUTO_DEPLOY_FIRST_FILE_GLOBS: string[] = [];
const MIN_AUTO_PREVIEW_DEBOUNCE_MS = 100;
const MAX_AUTO_PREVIEW_DEBOUNCE_MS = 60000;
const DEFAULT_AUTO_APPLY_MODE: AutoApplyMode = "smart";
const DEFAULT_AUTO_HOT_RELOAD_TIMEOUT_SEC = 90;
const DEFAULT_AUTO_HOT_RELOAD_DOCTOR_TIMEOUT_SEC = 8;
const DEFAULT_AUTO_CONNECT_TIMEOUT_MS = 20000;
const DEFAULT_AUTO_DIAGNOSTICS_TIMEOUT_MS = 5000;
const DEFAULT_AUTO_APPLY_LOG_LEVEL: AutoApplyLogLevel = "debug";
const LOG_LEVEL_WEIGHT: Record<AutoApplyLogLevel, number> = {
  off: 0,
  info: 1,
  debug: 2,
};
const HOT_RELOAD_NON_INJECTABLE_REASON_PREFIX = "HR_SOURCE_";
const HOT_RELOAD_DEPENDENCY_REFERENCE_REASON_CODE = "HR_DEPENDENCY_REQUIRES_REFERENCE_TYPES";
const HOT_RELOAD_DEPENDENCY_SOURCE_TOO_LARGE_REASON_CODE = "HR_HOT_RELOAD_DEPENDENCY_SOURCE_TOO_LARGE";
const SOURCE_FILE_EXCLUDE_GLOB = "{**/.build/**,**/build/**,**/DerivedData/**}";
const MAX_HOT_RELOAD_DEPENDENCY_FILES = 8;
const MAX_HOT_RELOAD_DEPENDENCY_SOURCE_BYTES = 300_000;
const MAX_HOT_RELOAD_SOURCE_FILE_SCAN = 200;
const MAX_INDEX_BOOTSTRAP_SOURCE_FILE_SCAN = 1200;
const deployPreferredFiles = new Set<string>();
const indexStore: IndexStore = new FileIndexStore();
const bootstrappedWorkspaceRoots = new Set<string>();
const workspaceIndexBootstrapInFlight = new Map<string, Promise<void>>();

type AutoApplyMode = "build" | "smart" | "hotReload";
type AutoApplyLogLevel = "off" | "info" | "debug";
type AutoApplyState =
  | "queued"
  | "planning"
  | "executing_preview"
  | "executing_hot_reload"
  | "fallback_preview"
  | "failed"
  | "done";

interface AutoApplyRequest {
  reason: string;
  resource: vscode.Uri;
  fileTraits?: AutoApplyFileTraits;
}

interface AutoHotReloadResult {
  ok: boolean;
  reason: string;
  reasonCode?: string;
}

interface AutoApplyTrace {
  traceId: string;
  logLevel: AutoApplyLogLevel;
  diagnosticsOnFailure: boolean;
  outputChannel: vscode.OutputChannel;
}

type AutoApplySetState = (
  next: AutoApplyState,
  fields?: Record<string, unknown>
) => void;

interface AutoApplyExecutionContext {
  request: AutoApplyRequest;
  workspaceConfig: vscode.WorkspaceConfiguration;
  applyConfig: AutoApplyConfig;
  plan: AutoApplyPlan;
  trace: AutoApplyTrace;
  setState: AutoApplySetState;
}

type AutoApplyExecutionResult =
  | {
      ok: true;
      terminalPath: AutoApplyPath;
    }
  | {
      ok: false;
      failedPath: AutoApplyPath;
      reason: string;
      reasonCode?: string;
    };

type AutoApplyExecutor = (
  context: AutoApplyExecutionContext
) => Promise<AutoApplyExecutionResult>;

type AutoApplyPath = "hot_reload" | "preview_deploy" | "preview_build";

interface AutoApplyConfig {
  mode: AutoApplyMode;
  autoBuildScriptPath?: string;
  deployScriptPath?: string;
  buildDeployScriptPath?: string;
  deployFirstGlobs: string[];
  logLevel: AutoApplyLogLevel;
  diagnosticsOnFailure: boolean;
}

interface AutoApplyPlan {
  mode: AutoApplyMode;
  path: AutoApplyPath;
  fileKey: string;
  relativePath: string | null;
  reasonCode: string;
  reasonDetail: string;
  scriptPathOverride?: string;
}

interface DoctorReport {
  status: string;
  recommendedPath: string;
  reasonCodes: string[];
  summary: string;
}

interface HotReloadDependencyRetry {
  sourceCode: string;
  includedFiles: string[];
}

type HotReloadDependencyRetryResult =
  | ({ kind: "retry" } & HotReloadDependencyRetry)
  | {
      kind: "blocked";
      reasonCode: string;
      reason: string;
    }
  | {
      kind: "unavailable";
      reason: string;
    };

type SwiftTypeKind = "struct" | "class" | "enum" | "protocol" | "actor" | "typealias";

interface AutoApplyFileTraits {
  hasReferenceTypeDeclarations: boolean;
  hasMainAttribute: boolean;
}

interface HotReloadTypeProvider {
  uri: vscode.Uri;
  source: string;
  relativePath: string;
  kind: SwiftTypeKind;
}

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
  const autoApplyOutput = vscode.window.createOutputChannel("Apus Auto Apply");
  autoApplyOutput.appendLine("[Apus] auto apply engine: v3 (dependency retry + deploy-first memory)");
  context.subscriptions.push(autoApplyOutput);
  for (const workspaceFolder of vscode.workspace.workspaceFolders ?? []) {
    void ensureWorkspaceIndexBootstrapped(workspaceFolder, autoApplyOutput).catch((error: unknown) => {
      console.warn("[Apus] auto apply index bootstrap failed:", error);
    });
  }

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

    vscode.commands.registerCommand("apus.showAutoApplyOutput", () => {
      autoApplyOutput.show(true);
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

  // Auto apply on save (debounced + serialized)
  let autoPreviewTimer: ReturnType<typeof setTimeout> | null = null;
  let pendingAutoRequestForTimer: AutoApplyRequest | null = null;
  let runningAutoApplyPromise: Promise<void> | null = null;
  let queuedAutoApplyRequest: AutoApplyRequest | null = null;

  const clearAutoPreviewTimer = (): void => {
    if (autoPreviewTimer) {
      clearTimeout(autoPreviewTimer);
      autoPreviewTimer = null;
    }
  };

  const runQueuedAutoApply = async (initial: AutoApplyRequest): Promise<void> => {
    let current: AutoApplyRequest | null = initial;
    while (current) {
      await runAutoApplyOnce(current, autoApplyOutput);
      const next = queuedAutoApplyRequest;
      queuedAutoApplyRequest = null;
      current = next;
    }
  };

  const queueAutoApply = (request: AutoApplyRequest): void => {
    if (runningAutoApplyPromise) {
      queuedAutoApplyRequest = request;
      const queuedConfig = readAutoApplyConfig(vscode.workspace.getConfiguration("apus", request.resource));
      const queueTrace = createAutoApplyTrace(request, queuedConfig, autoApplyOutput);
      logAutoApply(queueTrace, "debug", "auto_apply.queued", {
        reason: request.reason,
        resource_path: request.resource.fsPath,
      });
      return;
    }

    runningAutoApplyPromise = runQueuedAutoApply(request).finally(() => {
      runningAutoApplyPromise = null;
    });
  };

  const scheduleAutoPreview = (
    reason: string,
    resource: vscode.Uri,
    fileTraits?: AutoApplyFileTraits
  ): void => {
    const cfg = vscode.workspace.getConfiguration("apus", resource);
    const debounceMs = clampNumber(
      cfg.get<number>("autoPreviewDebounceMs", DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS),
      MIN_AUTO_PREVIEW_DEBOUNCE_MS,
      MAX_AUTO_PREVIEW_DEBOUNCE_MS,
      DEFAULT_AUTO_PREVIEW_DEBOUNCE_MS
    );

    pendingAutoRequestForTimer = { reason, resource, fileTraits };
    clearAutoPreviewTimer();
    autoPreviewTimer = setTimeout(() => {
      autoPreviewTimer = null;
      const request = pendingAutoRequestForTimer;
      pendingAutoRequestForTimer = null;
      if (!request) {
        return;
      }
      queueAutoApply(request);
    }, debounceMs);
  };

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((document) => {
      const match = matchAutoPreviewDocument(document);
      if (!match.shouldRun) {
        return;
      }
      const workspaceFolder = vscode.workspace.getWorkspaceFolder(document.uri);
      if (workspaceFolder) {
        void ensureWorkspaceIndexBootstrapped(workspaceFolder, autoApplyOutput).catch((error: unknown) => {
          console.warn("[Apus] auto apply index bootstrap failed:", error);
        });
      }
      void updateAutoApplyIndex(document.uri).catch((error: unknown) => {
        console.warn("[Apus] auto apply index update failed:", error);
      });
      const fileTraits = analyzeAutoApplyFileTraits(document.getText());
      scheduleAutoPreview(`save:${match.relativePath}`, document.uri, fileTraits);
    })
  );

  context.subscriptions.push({
    dispose: () => {
      clearAutoPreviewTimer();
      pendingAutoRequestForTimer = null;
      queuedAutoApplyRequest = null;
    },
  });

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

async function runAutoApplyOnce(
  request: AutoApplyRequest,
  outputChannel: vscode.OutputChannel
): Promise<void> {
  const workspaceConfig = vscode.workspace.getConfiguration("apus", request.resource);
  const applyConfig = readAutoApplyConfig(workspaceConfig);
  const trace = createAutoApplyTrace(request, applyConfig, outputChannel);
  const plan = planAutoApply(request, applyConfig);
  let state: AutoApplyState = "queued";
  const setState: AutoApplySetState = (next, fields = {}): void => {
    state = next;
    updateAutoApplyStatusBar(next, plan, fields);
    logAutoApply(trace, "debug", "state.transition", {
      state,
      reason: request.reason,
      resource_path: request.resource.fsPath,
      ...fields,
    });
  };

  logAutoApply(trace, "info", "auto_apply.started", {
    mode: plan.mode,
    reason: request.reason,
    resource_path: request.resource.fsPath,
  });

  setState("planning");
  logAutoApply(trace, "info", "auto_apply.plan", {
    mode: plan.mode,
    path: plan.path,
    reason_code: plan.reasonCode,
    reason_detail: plan.reasonDetail,
    relative_path: plan.relativePath ?? "",
    has_reference_type_declarations: request.fileTraits?.hasReferenceTypeDeclarations ?? false,
    has_main_attribute: request.fileTraits?.hasMainAttribute ?? false,
  });

  const indexEntry = await readAutoApplyIndexEntry(request.resource);
  if (indexEntry) {
    logAutoApply(trace, "debug", "auto_apply.index_context", {
      relative_path: indexEntry.relativePath,
      index_hit: true,
      hash_prefix: indexEntry.entry.hash.slice(0, 12),
      exports_count: indexEntry.entry.symbols.exports.length,
      uses_count: indexEntry.entry.symbols.uses.length,
    });
  } else {
    logAutoApply(trace, "debug", "auto_apply.index_context", {
      relative_path: plan.relativePath ?? "",
      index_hit: false,
    });
  }

  const executionContext: AutoApplyExecutionContext = {
    request,
    workspaceConfig,
    applyConfig,
    plan,
    trace,
    setState,
  };

  const executionResult = await executeAutoApplyPlan(executionContext);
  if (executionResult.ok) {
    setState("done", { terminal_path: executionResult.terminalPath });
    logAutoApply(trace, "info", "auto_apply.completed", {
      terminal_path: executionResult.terminalPath,
      fallback_used: false,
    });
    return;
  }

  setState("failed", {
    reason_code: executionResult.reasonCode ?? "unknown",
    failure_reason: oneLine(executionResult.reason, 260),
    failed_path: executionResult.failedPath,
  });
  logAutoApply(trace, "info", "auto_apply.failed", {
    reason_code: executionResult.reasonCode ?? "",
    failure_reason: executionResult.reason,
    failed_path: executionResult.failedPath,
  });

  if (trace.diagnosticsOnFailure) {
    await appendDiagnosticsSnapshot(trace);
  } else {
    logAutoApply(trace, "debug", "mcp.diagnostics.skipped", {
      reason: "disabled_by_config",
    });
  }

  const shouldFallbackFromHotReloadFailure = executionResult.failedPath === "hot_reload" && (
    plan.mode === "smart" || shouldFallbackPreviewAfterHotReloadFailure(executionResult.reasonCode)
  );
  if (shouldFallbackFromHotReloadFailure) {
    await executeFallbackPreviewDeploy(executionContext, executionResult);
    return;
  }

  setState("done", { terminal_path: executionResult.failedPath, terminal_status: "failed" });
  void vscode.window.showWarningMessage(
    `Apus auto apply failed: ${executionResult.reason}`
  );
}

function updateAutoApplyStatusBar(
  state: AutoApplyState,
  plan: AutoApplyPlan,
  fields: Record<string, unknown>
): void {
  const terminalStatus = typeof fields.terminal_status === "string" ? fields.terminal_status : "";
  const terminalPathRaw = typeof fields.terminal_path === "string" ? fields.terminal_path : plan.path;
  const reasonCode = typeof fields.reason_code === "string" && fields.reason_code.length > 0
    ? fields.reason_code
    : "failed";

  let indicatorState: ApplyIndicatorState;
  let detail: string;

  if (state === "failed" || (state === "done" && terminalStatus === "failed")) {
    indicatorState = "failed";
    detail = reasonCode;
  } else if (state === "done") {
    indicatorState = "success";
    detail = formatApplyPathLabel(terminalPathRaw);
  } else {
    indicatorState = "running";
    detail = formatRunningApplyLabel(state, plan, fields);
  }

  statusBar.updateApply(indicatorState, detail);
}

function formatApplyPathLabel(pathValue: string): string {
  switch (pathValue) {
    case "hot_reload":
      return "hot reload";
    case "preview_build":
      return "build";
    case "preview_deploy":
      return "build+deploy";
    default:
      return pathValue;
  }
}

function formatRunningApplyLabel(
  state: AutoApplyState,
  plan: AutoApplyPlan,
  fields: Record<string, unknown>
): string {
  if (state === "executing_preview") {
    const previewPath = typeof fields.preview_path === "string" ? fields.preview_path : plan.path;
    return formatApplyPathLabel(previewPath);
  }

  switch (state) {
    case "queued":
      return "queued";
    case "planning":
      return "planning";
    case "executing_hot_reload":
      return "hot reload";
    case "fallback_preview":
      return "fallback deploy";
    default:
      return formatApplyPathLabel(plan.path);
  }
}

const AUTO_APPLY_EXECUTORS: Record<AutoApplyPath, AutoApplyExecutor> = {
  hot_reload: executeHotReloadStrategy,
  preview_build: executePreviewStrategy,
  preview_deploy: executePreviewStrategy,
};

async function executeAutoApplyPlan(
  context: AutoApplyExecutionContext
): Promise<AutoApplyExecutionResult> {
  return AUTO_APPLY_EXECUTORS[context.plan.path](context);
}

async function executePreviewStrategy(
  context: AutoApplyExecutionContext
): Promise<AutoApplyExecutionResult> {
  const { request, plan, setState } = context;
  setState("executing_preview", { preview_path: plan.path });
  await runPreviewBuildFallback(
    `${request.reason}|plan:${plan.reasonCode}`,
    plan.scriptPathOverride
  );
  return { ok: true, terminalPath: plan.path };
}

async function executeHotReloadStrategy(
  context: AutoApplyExecutionContext
): Promise<AutoApplyExecutionResult> {
  const { request, workspaceConfig, setState, trace } = context;
  setState("executing_hot_reload");
  const hotReloadResult = await runAutoHotReload(request, workspaceConfig, trace);
  if (hotReloadResult.ok) {
    return { ok: true, terminalPath: "hot_reload" };
  }
  return {
    ok: false,
    failedPath: "hot_reload",
    reason: hotReloadResult.reason,
    reasonCode: hotReloadResult.reasonCode,
  };
}

async function executeFallbackPreviewDeploy(
  context: AutoApplyExecutionContext,
  failedResult: Extract<AutoApplyExecutionResult, { ok: false }>
): Promise<void> {
  const { request, applyConfig, setState, trace } = context;
  setState("fallback_preview", { fallback_path: "preview_deploy" });
  logAutoApply(trace, "info", "auto_apply.fallback", {
    fallback_path: "preview_deploy",
    from_path: failedResult.failedPath,
    reason_code: failedResult.reasonCode ?? "unknown",
  });
  await runPreviewBuildFallback(
    `${request.reason}|fallback:${failedResult.reasonCode ?? "unknown"}`,
    applyConfig.buildDeployScriptPath ?? applyConfig.deployScriptPath
  );
  setState("done", { terminal_path: "preview_deploy" });
  logAutoApply(trace, "info", "auto_apply.completed", {
    terminal_path: "preview_deploy",
    fallback_used: true,
    reason_code: failedResult.reasonCode ?? "unknown",
  });
}

async function runAutoHotReload(
  request: AutoApplyRequest,
  config: vscode.WorkspaceConfiguration,
  trace: AutoApplyTrace
): Promise<AutoHotReloadResult> {
  const fileKey = hotReloadFileKey(request.resource);
  const connected = await ensureClientConnected(DEFAULT_AUTO_CONNECT_TIMEOUT_MS);
  if (!connected) {
    return {
      ok: false,
      reason: "Not connected to Apus runtime.",
      reasonCode: "HR_CLIENT_NOT_CONNECTED",
    };
  }

  const workspaceFolder = vscode.workspace.getWorkspaceFolder(request.resource);
  if (!workspaceFolder) {
    return {
      ok: false,
      reason: "No workspace folder found for the saved file.",
      reasonCode: "HR_WORKSPACE_NOT_FOUND",
    };
  }

  const relativePath = normalizeFsPath(
    path.relative(workspaceFolder.uri.fsPath, request.resource.fsPath)
  );
  if (!relativePath || relativePath.startsWith("..")) {
    return {
      ok: false,
      reason: "Saved file is outside workspace root.",
      reasonCode: "HR_FILE_OUTSIDE_WORKSPACE",
    };
  }

  let sourceCode = "";
  try {
    const bytes = await vscode.workspace.fs.readFile(request.resource);
    sourceCode = Buffer.from(bytes).toString("utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      reason: `Failed to read file for hot reload: ${message}`,
      reasonCode: "HR_SOURCE_READ_FAILED",
    };
  }

  if (!sourceCode.trim()) {
    return {
      ok: false,
      reason: "Source file is empty after save.",
      reasonCode: "HR_SOURCE_EMPTY",
    };
  }

  try {
    const doctorTimeoutSec = clampNumber(
      config.get<number>("autoHotReloadDoctorTimeoutSec", DEFAULT_AUTO_HOT_RELOAD_DOCTOR_TIMEOUT_SEC),
      1,
      120,
      DEFAULT_AUTO_HOT_RELOAD_DOCTOR_TIMEOUT_SEC
    );

    const doctorRaw = await callToolWithReconnectRetry(
      "hot_reload_doctor",
      {
        source_code: sourceCode,
        original_path: relativePath,
      },
      doctorTimeoutSec * 1000,
      trace
    );

    if (isToolResultError(doctorRaw)) {
      return {
        ok: false,
        reason: extractToolResultText(doctorRaw),
        reasonCode: "HR_DOCTOR_TOOL_ERROR",
      };
    }

    const doctor = parseDoctorReport(doctorRaw);
    if (!doctor) {
      return {
        ok: false,
        reason: "hot_reload_doctor returned an invalid payload.",
        reasonCode: "HR_DOCTOR_PARSE_FAILED",
      };
    }

    logAutoApply(trace, "debug", "hot_reload.doctor", {
      status: doctor.status,
      recommended_path: doctor.recommendedPath,
      reason_codes: doctor.reasonCodes,
    });
    if (doctor.summary) {
      logAutoApply(trace, "debug", "hot_reload.doctor_summary", {
        summary: doctor.summary,
      });
    }

    if (doctor.status === "FAIL" || doctor.recommendedPath === "preview_changes") {
      const doctorReasonCode = doctor.reasonCodes[0] ?? "HR_DOCTOR_BLOCKING_FAILURE";
      if (shouldRememberDeployFirstFromReasonCode(doctorReasonCode)) {
        deployPreferredFiles.add(fileKey);
      }
      return {
        ok: false,
        reason: doctor.summary || "Doctor reported blocking issues.",
        reasonCode: doctorReasonCode,
      };
    }

    const hotReloadTimeoutSec = clampNumber(
      config.get<number>("autoHotReloadTimeoutSec", DEFAULT_AUTO_HOT_RELOAD_TIMEOUT_SEC),
      5,
      300,
      DEFAULT_AUTO_HOT_RELOAD_TIMEOUT_SEC
    );
    const includeScreenshot = config.get<boolean>("autoHotReloadIncludeScreenshot", false);

    logAutoApply(trace, "debug", "hot_reload.request", {
      relative_path: relativePath,
      include_screenshot: includeScreenshot,
      timeout_sec: hotReloadTimeoutSec,
    });

    const hotReloadRaw = await callToolWithReconnectRetry(
      "hot_reload",
      {
        source_code: sourceCode,
        original_path: relativePath,
        include_screenshot: includeScreenshot,
      },
      hotReloadTimeoutSec * 1000,
      trace
    );

    if (isToolResultError(hotReloadRaw)) {
      const initialError = extractToolResultText(hotReloadRaw);
      const initialReasonCode = extractRuntimeReasonCode(initialError) ?? "HR_HOT_RELOAD_FAILED";
      const missingTypes = extractMissingTypeNames(initialError);

      if (missingTypes.length > 0) {
        logAutoApply(trace, "debug", "hot_reload.missing_types", {
          missing_types: missingTypes,
        });

        const dependencyRetry = await buildHotReloadDependencyRetry({
          workspaceFolder,
          changedFile: request.resource,
          sourceCode,
          missingTypes,
        });

        if (dependencyRetry.kind === "retry") {
          logAutoApply(trace, "debug", "hot_reload.dependency_retry", {
            support_files_count: dependencyRetry.includedFiles.length,
            support_files: dependencyRetry.includedFiles,
          });

          const retryRaw = await callToolWithReconnectRetry(
            "hot_reload",
            {
              source_code: dependencyRetry.sourceCode,
              original_path: relativePath,
              include_screenshot: includeScreenshot,
            },
            hotReloadTimeoutSec * 1000,
            trace
          );

          if (!isToolResultError(retryRaw)) {
            const retrySummary = oneLine(extractToolResultText(retryRaw), 220);
            if (retrySummary) {
              logAutoApply(trace, "debug", "hot_reload.dependency_retry_result", {
                summary: retrySummary,
              });
            }
            deployPreferredFiles.delete(fileKey);
            return { ok: true, reason: "Hot reload succeeded after dependency retry." };
          }

          const retryError = extractToolResultText(retryRaw);
          deployPreferredFiles.add(fileKey);
          return {
            ok: false,
            reason: retryError,
            reasonCode: extractRuntimeReasonCode(retryError) ?? "HR_HOT_RELOAD_FAILED",
          };
        }

        if (dependencyRetry.kind === "blocked") {
          logAutoApply(trace, "debug", "hot_reload.dependency_retry_blocked", {
            reason_code: dependencyRetry.reasonCode,
            reason: dependencyRetry.reason,
          });
          deployPreferredFiles.add(fileKey);
          return {
            ok: false,
            reason: dependencyRetry.reason,
            reasonCode: dependencyRetry.reasonCode,
          };
        }

        logAutoApply(trace, "debug", "hot_reload.dependency_retry_skipped", {
          reason: dependencyRetry.reason,
        });
        deployPreferredFiles.add(fileKey);
      }

      if (shouldRememberDeployFirstFromReasonCode(initialReasonCode)) {
        deployPreferredFiles.add(fileKey);
      }

      return {
        ok: false,
        reason: initialError,
        reasonCode: initialReasonCode,
      };
    }

    const summary = oneLine(extractToolResultText(hotReloadRaw), 220);
    if (summary) {
      logAutoApply(trace, "debug", "hot_reload.result", {
        summary,
      });
    }

    deployPreferredFiles.delete(fileKey);
    return { ok: true, reason: "Hot reload succeeded." };
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      reason: message,
      reasonCode: "HR_HOT_RELOAD_EXCEPTION",
    };
  }
}

async function runPreviewBuildFallback(
  reason: string,
  scriptPathOverride?: string
): Promise<void> {
  await vscode.commands.executeCommand("apus.previewChanges", {
    source: "auto",
    reason,
    scriptPathOverride: scriptPathOverride || undefined,
  });
}

function readAutoApplyMode(config: vscode.WorkspaceConfiguration): AutoApplyMode {
  const value = config.get<string>("autoApplyMode", DEFAULT_AUTO_APPLY_MODE)?.trim() || DEFAULT_AUTO_APPLY_MODE;
  if (value === "smart" || value === "hotReload" || value === "build") {
    return value;
  }
  return DEFAULT_AUTO_APPLY_MODE;
}

function readAutoApplyLogLevel(config: vscode.WorkspaceConfiguration): AutoApplyLogLevel {
  const value = config
    .get<string>("autoApplyLogLevel", DEFAULT_AUTO_APPLY_LOG_LEVEL)
    ?.trim() || DEFAULT_AUTO_APPLY_LOG_LEVEL;
  if (value === "off" || value === "info" || value === "debug") {
    return value;
  }
  return DEFAULT_AUTO_APPLY_LOG_LEVEL;
}

function createAutoApplyTrace(
  request: AutoApplyRequest,
  applyConfig: AutoApplyConfig,
  outputChannel: vscode.OutputChannel
): AutoApplyTrace {
  const traceSeed = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const relativePath = resourceRelativePath(request.resource) || "unknown";
  const traceId = `${traceSeed}-${relativePath.replace(/[^a-zA-Z0-9]+/g, "_").slice(-18)}`;

  return {
    traceId,
    logLevel: applyConfig.logLevel,
    diagnosticsOnFailure: applyConfig.diagnosticsOnFailure,
    outputChannel,
  };
}

function logAutoApply(
  trace: AutoApplyTrace,
  level: Exclude<AutoApplyLogLevel, "off">,
  event: string,
  fields: Record<string, unknown> = {}
): void {
  if (LOG_LEVEL_WEIGHT[trace.logLevel] < LOG_LEVEL_WEIGHT[level]) {
    return;
  }

  const payload: Record<string, unknown> = {
    ts: new Date().toISOString(),
    trace_id: trace.traceId,
    level,
    event,
    ...fields,
  };
  trace.outputChannel.appendLine(`[Apus] ${JSON.stringify(payload)}`);
}

function readAutoApplyConfig(config: vscode.WorkspaceConfiguration): AutoApplyConfig {
  const mode = readAutoApplyMode(config);
  const logLevel = readAutoApplyLogLevel(config);
  const diagnosticsOnFailure = config.get<boolean>("autoApplyDiagnosticsOnFailure", true);
  const autoBuildScriptPath = config
    .get<string>("autoPreviewScriptPath", DEFAULT_AUTO_PREVIEW_SCRIPT_PATH)
    ?.trim();
  const deployScriptPath = config
    .get<string>("previewChangesScriptPath", "ExampleApp/build-and-run.sh --deploy")
    ?.trim();
  const buildDeployScriptPath = toBuildDeployScriptPath(deployScriptPath);
  const configuredDeployFirstGlobs = config.get<string[]>(
    "autoDeployFirstFileGlobs",
    DEFAULT_AUTO_DEPLOY_FIRST_FILE_GLOBS
  ) ?? DEFAULT_AUTO_DEPLOY_FIRST_FILE_GLOBS;
  const deployFirstGlobs = configuredDeployFirstGlobs
    .map((glob) => normalizeFsPath(glob.trim()))
    .filter((glob) => glob.length > 0);

  return {
    mode,
    autoBuildScriptPath,
    deployScriptPath,
    buildDeployScriptPath,
    deployFirstGlobs,
    logLevel,
    diagnosticsOnFailure,
  };
}

async function ensureWorkspaceIndexBootstrapped(
  workspaceFolder: vscode.WorkspaceFolder,
  outputChannel?: vscode.OutputChannel
): Promise<void> {
  const workspaceRoot = workspaceFolder.uri.fsPath;
  const workspaceKey = normalizeFsPath(workspaceRoot);
  if (bootstrappedWorkspaceRoots.has(workspaceKey)) {
    return;
  }

  const pending = workspaceIndexBootstrapInFlight.get(workspaceKey);
  if (pending) {
    await pending;
    return;
  }

  const bootstrapPromise = (async (): Promise<void> => {
    const existing = await indexStore.load(workspaceRoot);
    const existingFiles = existing?.files ?? {};

    const sourceFiles = await vscode.workspace.findFiles(
      new vscode.RelativePattern(workspaceFolder, "**/Sources/**/*.swift"),
      SOURCE_FILE_EXCLUDE_GLOB,
      MAX_INDEX_BOOTSTRAP_SOURCE_FILE_SCAN
    );
    if (sourceFiles.length === 0) {
      bootstrappedWorkspaceRoots.add(workspaceKey);
      return;
    }

    outputChannel?.appendLine(
      `[Apus] index bootstrap: scanning ${sourceFiles.length} Swift files (${workspaceFolder.name})`
    );

    const entries: FileIndexEntry[] = [];
    let skippedUnchanged = 0;
    for (const uri of sourceFiles) {
      const relativePath = normalizeFsPath(path.relative(workspaceRoot, uri.fsPath));
      if (!relativePath || relativePath.startsWith("..")) {
        continue;
      }

      try {
        const stat = await vscode.workspace.fs.stat(uri);
        const previous = existingFiles[relativePath];
        if (previous && previous.mtimeMs === stat.mtime && previous.size === stat.size) {
          skippedUnchanged += 1;
          continue;
        }

        const bytes = await vscode.workspace.fs.readFile(uri);
        const content = Buffer.from(bytes).toString("utf8");
        entries.push(
          buildFileIndexEntry({
            relativePath,
            content,
            size: stat.size,
            mtimeMs: stat.mtime,
          })
        );
      } catch {
        continue;
      }
    }

    if (entries.length > 0) {
      await indexStore.upsertMany(workspaceRoot, entries);
    }

    bootstrappedWorkspaceRoots.add(workspaceKey);
    outputChannel?.appendLine(
      `[Apus] index bootstrap: ready (${entries.length} updated, ${skippedUnchanged} unchanged)`
    );
  })()
    .finally(() => {
      workspaceIndexBootstrapInFlight.delete(workspaceKey);
    });

  workspaceIndexBootstrapInFlight.set(workspaceKey, bootstrapPromise);
  await bootstrapPromise;
}

async function updateAutoApplyIndex(resource: vscode.Uri): Promise<void> {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(resource);
  if (!workspaceFolder) {
    return;
  }

  const relativePath = resourceRelativePath(resource);
  if (!relativePath) {
    return;
  }

  const bytes = await vscode.workspace.fs.readFile(resource);
  const content = Buffer.from(bytes).toString("utf8");
  const stat = await vscode.workspace.fs.stat(resource);
  const entry = buildFileIndexEntry({
    relativePath,
    content,
    size: stat.size,
    mtimeMs: stat.mtime,
  });

  const workspaceRoot = workspaceFolder.uri.fsPath;
  const previous = await indexStore.get(workspaceRoot, relativePath);
  if (previous && previous.hash === entry.hash && previous.mtimeMs === entry.mtimeMs) {
    return;
  }

  await indexStore.upsert(workspaceRoot, entry);
}

async function readAutoApplyIndexEntry(resource: vscode.Uri): Promise<{
  relativePath: string;
  entry: FileIndexEntry;
} | null> {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(resource);
  if (!workspaceFolder) {
    return null;
  }

  const relativePath = resourceRelativePath(resource);
  if (!relativePath) {
    return null;
  }

  const entry = await indexStore.get(workspaceFolder.uri.fsPath, relativePath);
  if (!entry) {
    return null;
  }

  return { relativePath, entry };
}

function planAutoApply(request: AutoApplyRequest, applyConfig: AutoApplyConfig): AutoApplyPlan {
  const { mode, autoBuildScriptPath, deployScriptPath, buildDeployScriptPath, deployFirstGlobs } = applyConfig;
  const fileKey = hotReloadFileKey(request.resource);
  const relativePath = resourceRelativePath(request.resource);

  if (mode === "build") {
    return {
      mode,
      path: "preview_build",
      fileKey,
      relativePath,
      reasonCode: "PLAN_MODE_BUILD",
      reasonDetail: "autoApplyMode=build",
      scriptPathOverride: autoBuildScriptPath,
    };
  }

  if (mode === "smart" && relativePath) {
    const isConfiguredDeployFirst = deployFirstGlobs.some((glob) => matchesGlob(relativePath, glob));
    if (isConfiguredDeployFirst) {
      return {
        mode,
        path: "preview_deploy",
        fileKey,
        relativePath,
        reasonCode: "PLAN_DEPLOY_FIRST_CONFIG",
        reasonDetail: relativePath,
        scriptPathOverride: buildDeployScriptPath ?? deployScriptPath,
      };
    }
  }

  if (mode === "smart" && deployPreferredFiles.has(fileKey)) {
    return {
      mode,
      path: "preview_deploy",
      fileKey,
      relativePath,
      reasonCode: "PLAN_DEPLOY_FIRST_MEMORY",
      reasonDetail: relativePath ?? fileKey,
      scriptPathOverride: buildDeployScriptPath ?? deployScriptPath,
    };
  }

  return {
    mode,
    path: "hot_reload",
    fileKey,
    relativePath,
    reasonCode: "PLAN_HOT_RELOAD",
    reasonDetail: relativePath ?? fileKey,
  };
}

async function ensureClientConnected(timeoutMs: number): Promise<boolean> {
  if (client.getState() === "connected") {
    return true;
  }

  if (client.getState() === "disconnected") {
    client.connect();
  }

  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      cleanup();
      resolve(client.getState() === "connected");
    }, Math.max(500, timeoutMs));

    const onStateChange = (state: unknown): void => {
      if (state === "connected") {
        cleanup();
        resolve(true);
      }
    };

    const cleanup = (): void => {
      clearTimeout(timer);
      client.off("stateChange", onStateChange);
    };

    client.on("stateChange", onStateChange);
  });
}

async function callToolWithReconnectRetry(
  toolName: string,
  args: Record<string, unknown>,
  timeoutMs: number,
  trace: AutoApplyTrace
): Promise<unknown> {
  try {
    return await client.callTool(toolName, args, { timeoutMs });
  } catch (error: unknown) {
    if (!isTransientConnectionError(error)) {
      throw error;
    }

    const message = error instanceof Error ? error.message : String(error);
    logAutoApply(trace, "debug", "mcp.transient_connection_error", {
      tool_name: toolName,
      message: oneLine(message, 120),
    });

    const reconnected = await ensureClientConnected(DEFAULT_AUTO_CONNECT_TIMEOUT_MS);
    if (!reconnected) {
      throw error;
    }

    return await client.callTool(toolName, args, { timeoutMs });
  }
}

async function appendDiagnosticsSnapshot(trace: AutoApplyTrace): Promise<void> {
  const connected = await ensureClientConnected(DEFAULT_AUTO_DIAGNOSTICS_TIMEOUT_MS);
  if (!connected) {
    logAutoApply(trace, "info", "mcp.diagnostics.unavailable", {
      reason: "runtime_not_connected",
    });
    return;
  }

  try {
    const raw = await callToolWithReconnectRetry(
      "get_diagnostics",
      {},
      DEFAULT_AUTO_DIAGNOSTICS_TIMEOUT_MS,
      trace
    );
    if (isToolResultError(raw)) {
      logAutoApply(trace, "info", "mcp.diagnostics.error", {
        message: oneLine(extractToolResultText(raw), 220),
      });
      return;
    }

    const text = oneLine(extractToolResultText(raw), 260);
    logAutoApply(trace, "info", "mcp.diagnostics.snapshot", {
      summary: text,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    logAutoApply(trace, "info", "mcp.diagnostics.exception", {
      message: oneLine(message, 180),
    });
  }
}

function isTransientConnectionError(error: unknown): boolean {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return (
    message.includes("connection closed") ||
    message.includes("socket closed") ||
    message.includes("not connected") ||
    message.includes("econnreset")
  );
}

function parseDoctorReport(result: unknown): DoctorReport | null {
  const text = extractToolResultText(result).trim();
  if (!text) {
    return null;
  }

  try {
    const parsed: unknown = JSON.parse(text);
    if (!isRecord(parsed)) {
      return null;
    }

    const status = typeof parsed.status === "string" ? parsed.status : "FAIL";
    const recommendedPath =
      typeof parsed.recommended_path === "string" ? parsed.recommended_path : "preview_changes";
    const reasonCodes = Array.isArray(parsed.reason_codes)
      ? parsed.reason_codes.filter((item): item is string => typeof item === "string")
      : [];
    const summary = typeof parsed.summary === "string" ? parsed.summary : "";

    return { status, recommendedPath, reasonCodes, summary };
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function oneLine(value: string, maxLength: number): string {
  const flattened = value.replace(/\s+/g, " ").trim();
  if (flattened.length <= maxLength) {
    return flattened;
  }
  return `${flattened.slice(0, Math.max(0, maxLength - 1))}…`;
}

function normalizeFsPath(value: string): string {
  return value.replace(/\\/g, "/").replace(/^\.\/+/, "");
}

function analyzeAutoApplyFileTraits(source: string): AutoApplyFileTraits {
  if (!source || !source.trim()) {
    return {
      hasReferenceTypeDeclarations: false,
      hasMainAttribute: false,
    };
  }

  const sanitized = sanitizeSwiftSourceForDeclarationChecks(source);
  return {
    hasReferenceTypeDeclarations: /^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|indirect|nonisolated|dynamic|override)\s+)*(?:class|actor|protocol)\s+[A-Za-z_][A-Za-z0-9_]*\b/m.test(
      sanitized
    ),
    hasMainAttribute: /^\s*@main\b/m.test(sanitized),
  };
}

function sanitizeSwiftSourceForDeclarationChecks(source: string): string {
  const withoutStrings = source
    .replace(/"""[\s\S]*?"""/g, "\"\"")
    .replace(/"(?:\\.|[^"\\])*"/g, "\"\"");
  const withoutBlockComments = withoutStrings.replace(/\/\*[\s\S]*?\*\//g, "");
  return withoutBlockComments.replace(/\/\/.*$/gm, "");
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

function hotReloadFileKey(resource: vscode.Uri): string {
  return normalizeFsPath(resource.fsPath);
}

function resourceRelativePath(resource: vscode.Uri): string | null {
  const workspaceFolder = vscode.workspace.getWorkspaceFolder(resource);
  if (!workspaceFolder) {
    return null;
  }

  const relativePath = normalizeFsPath(path.relative(workspaceFolder.uri.fsPath, resource.fsPath));
  if (!relativePath || relativePath.startsWith("..")) {
    return null;
  }

  return relativePath;
}

function toBuildDeployScriptPath(deployScriptPath: string | undefined): string | undefined {
  if (!deployScriptPath) {
    return deployScriptPath;
  }

  const normalized = deployScriptPath.replace(/\s+--deploy(\s|$)/g, " ").trim();
  return normalized.length > 0 ? normalized : deployScriptPath;
}

function extractMissingTypeNames(errorText: string): string[] {
  if (!errorText) {
    return [];
  }

  const names = new Set<string>();
  const pattern = /cannot find(?: type)? '([A-Za-z_][A-Za-z0-9_]*)' in scope/g;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(errorText)) !== null) {
    const name = match[1];
    if (name.length > 0) {
      names.add(name);
    }
  }

  return Array.from(names).slice(0, 12);
}

function extractRuntimeReasonCode(errorText: string): string | null {
  if (!errorText) {
    return null;
  }

  const matches = errorText.match(/\bHR_[A-Z0-9_]+\b/g);
  if (!matches || matches.length === 0) {
    return null;
  }

  return matches[0] ?? null;
}

function shouldRememberDeployFirstFromReasonCode(reasonCode: string | undefined): boolean {
  if (!reasonCode || reasonCode.length === 0) {
    return false;
  }

  return (
    reasonCode.startsWith(HOT_RELOAD_NON_INJECTABLE_REASON_PREFIX) ||
    reasonCode === HOT_RELOAD_DEPENDENCY_REFERENCE_REASON_CODE ||
    reasonCode === HOT_RELOAD_DEPENDENCY_SOURCE_TOO_LARGE_REASON_CODE
  );
}

function shouldFallbackPreviewAfterHotReloadFailure(reasonCode: string | undefined): boolean {
  if (!reasonCode || reasonCode.length === 0) {
    return false;
  }

  return (
    reasonCode.startsWith(HOT_RELOAD_NON_INJECTABLE_REASON_PREFIX) ||
    reasonCode === HOT_RELOAD_DEPENDENCY_REFERENCE_REASON_CODE ||
    reasonCode === HOT_RELOAD_DEPENDENCY_SOURCE_TOO_LARGE_REASON_CODE
  );
}

async function buildHotReloadDependencyRetry(input: {
  workspaceFolder: vscode.WorkspaceFolder;
  changedFile: vscode.Uri;
  sourceCode: string;
  missingTypes: string[];
}): Promise<HotReloadDependencyRetryResult> {
  const { workspaceFolder, changedFile, sourceCode, missingTypes } = input;
  if (missingTypes.length === 0) {
    return { kind: "unavailable", reason: "missing type list was empty" };
  }

  const typeMatchers = new Map<string, RegExp>();
  for (const typeName of missingTypes) {
    typeMatchers.set(
      typeName,
      new RegExp(`\\b(struct|class|enum|protocol|actor|typealias)\\s+${escapeRegExp(typeName)}\\b`)
    );
  }

  const unresolved = new Set(missingTypes);
  const providerByType = new Map<string, HotReloadTypeProvider>();
  const sourceTreePrefix = sourceTreePrefixForRelativePath(resourceRelativePath(changedFile));

  await ensureWorkspaceIndexBootstrapped(workspaceFolder).catch(() => {
    // Ignore bootstrap failures and fallback to scan-based resolution.
  });

  await resolveHotReloadProvidersFromIndex({
    workspaceFolder,
    changedFile,
    sourceTreePrefix,
    typeMatchers,
    unresolved,
    providerByType,
  });

  if (unresolved.size > 0) {
    await resolveHotReloadProvidersByScan({
      workspaceFolder,
      changedFile,
      sourceTreePrefix,
      typeMatchers,
      unresolved,
      providerByType,
    });
  }

  if (providerByType.size === 0) {
    return { kind: "unavailable", reason: "supporting files were not resolved" };
  }

  const includedUris = new Set<string>();
  const includedFiles: string[] = [];
  const sourceChunks: string[] = [];
  const blockedReferenceTypeNames: string[] = [];

  for (const typeName of missingTypes) {
    const provider = providerByType.get(typeName);
    if (!provider) {
      continue;
    }

    // Avoid retrying injections that require reference/protocol metadata from other files.
    // That path is prone to runtime instability; prefer fallback deploy for safety.
    if (provider.kind === "class" || provider.kind === "protocol" || provider.kind === "actor") {
      blockedReferenceTypeNames.push(typeName);
      continue;
    }

    const key = normalizeFsPath(provider.uri.fsPath);
    if (includedUris.has(key)) {
      continue;
    }
    if (includedFiles.length >= MAX_HOT_RELOAD_DEPENDENCY_FILES) {
      break;
    }

    includedUris.add(key);
    includedFiles.push(provider.relativePath);
    sourceChunks.push(provider.source.trim());
  }

  if (blockedReferenceTypeNames.length > 0) {
    return {
      kind: "blocked",
      reasonCode: HOT_RELOAD_DEPENDENCY_REFERENCE_REASON_CODE,
      reason: `Hot reload requires external reference-type dependencies (${blockedReferenceTypeNames.join(", ")}). Use preview/deploy for this edit.`,
    };
  }

  if (sourceChunks.length === 0) {
    return { kind: "unavailable", reason: "no injectable support files were available" };
  }

  const composedSource = `${sourceChunks.join("\n\n")}\n\n${sourceCode}`.trim();
  const sourceBytes = Buffer.byteLength(composedSource, "utf8");
  if (sourceBytes > MAX_HOT_RELOAD_DEPENDENCY_SOURCE_BYTES) {
    return {
      kind: "blocked",
      reasonCode: HOT_RELOAD_DEPENDENCY_SOURCE_TOO_LARGE_REASON_CODE,
      reason: `Hot reload dependency payload is too large (${sourceBytes} bytes). Use preview/deploy for this edit.`,
    };
  }

  return { kind: "retry", sourceCode: composedSource, includedFiles };
}

async function resolveHotReloadProvidersFromIndex(input: {
  workspaceFolder: vscode.WorkspaceFolder;
  changedFile: vscode.Uri;
  sourceTreePrefix: string | null;
  typeMatchers: Map<string, RegExp>;
  unresolved: Set<string>;
  providerByType: Map<string, HotReloadTypeProvider>;
}): Promise<void> {
  const {
    workspaceFolder,
    changedFile,
    sourceTreePrefix,
    typeMatchers,
    unresolved,
    providerByType,
  } = input;
  if (unresolved.size === 0) {
    return;
  }

  const workspaceRoot = workspaceFolder.uri.fsPath;
  const snapshot = await indexStore.load(workspaceRoot);
  if (!snapshot) {
    return;
  }

  const changedRelativePath = normalizeFsPath(
    path.relative(workspaceRoot, changedFile.fsPath)
  );
  const candidatePathByType = new Map<string, string>();
  for (const entry of Object.values(snapshot.files)) {
    if (!isPathInSourceTree(entry.relativePath, sourceTreePrefix)) {
      continue;
    }
    if (entry.relativePath === changedRelativePath) {
      continue;
    }
    for (const exportedType of entry.symbols.exports) {
      if (!unresolved.has(exportedType) || candidatePathByType.has(exportedType)) {
        continue;
      }
      candidatePathByType.set(exportedType, entry.relativePath);
    }
  }

  for (const [typeName, relativePath] of candidatePathByType.entries()) {
    if (!unresolved.has(typeName)) {
      continue;
    }

    const matcher = typeMatchers.get(typeName);
    if (!matcher) {
      continue;
    }

    const uri = vscode.Uri.file(path.join(workspaceRoot, relativePath));
    let fileSource = "";
    try {
      const bytes = await vscode.workspace.fs.readFile(uri);
      fileSource = Buffer.from(bytes).toString("utf8");
    } catch {
      continue;
    }

    if (!fileSource.trim() || fileSource.includes("@main")) {
      continue;
    }

    const match = matcher.exec(fileSource);
    if (!match) {
      continue;
    }

    const kind = (match[1] as SwiftTypeKind) || "struct";
    providerByType.set(typeName, { uri, source: fileSource, relativePath, kind });
    unresolved.delete(typeName);
  }
}

async function resolveHotReloadProvidersByScan(input: {
  workspaceFolder: vscode.WorkspaceFolder;
  changedFile: vscode.Uri;
  sourceTreePrefix: string | null;
  typeMatchers: Map<string, RegExp>;
  unresolved: Set<string>;
  providerByType: Map<string, HotReloadTypeProvider>;
}): Promise<void> {
  const {
    workspaceFolder,
    changedFile,
    sourceTreePrefix,
    typeMatchers,
    unresolved,
    providerByType,
  } = input;
  if (unresolved.size === 0) {
    return;
  }

  const sourceFiles = await vscode.workspace.findFiles(
    new vscode.RelativePattern(workspaceFolder, sourceTreeGlobPattern(sourceTreePrefix)),
    SOURCE_FILE_EXCLUDE_GLOB,
    MAX_HOT_RELOAD_SOURCE_FILE_SCAN
  );
  const changedPath = normalizeFsPath(changedFile.fsPath);
  const includedProviderPaths = new Set(
    Array.from(providerByType.values()).map((provider) => normalizeFsPath(provider.uri.fsPath))
  );

  for (const uri of sourceFiles) {
    if (unresolved.size === 0) {
      break;
    }

    const normalizedPath = normalizeFsPath(uri.fsPath);
    if (normalizedPath === changedPath || includedProviderPaths.has(normalizedPath)) {
      continue;
    }

    const relativePath = normalizeFsPath(path.relative(workspaceFolder.uri.fsPath, uri.fsPath));
    if (!relativePath || relativePath.startsWith("..")) {
      continue;
    }
    if (!isPathInSourceTree(relativePath, sourceTreePrefix)) {
      continue;
    }

    let fileSource = "";
    try {
      const bytes = await vscode.workspace.fs.readFile(uri);
      fileSource = Buffer.from(bytes).toString("utf8");
    } catch {
      continue;
    }

    if (!fileSource.trim() || fileSource.includes("@main")) {
      continue;
    }

    for (const typeName of Array.from(unresolved)) {
      const matcher = typeMatchers.get(typeName);
      if (!matcher) {
        continue;
      }

      const match = matcher.exec(fileSource);
      if (!match) {
        continue;
      }

      const kind = (match[1] as SwiftTypeKind) || "struct";
      providerByType.set(typeName, { uri, source: fileSource, relativePath, kind });
      unresolved.delete(typeName);
      includedProviderPaths.add(normalizedPath);
    }
  }
}

function sourceTreePrefixForRelativePath(relativePath: string | null): string | null {
  if (!relativePath) {
    return null;
  }
  if (relativePath.startsWith("Sources/")) {
    return "";
  }

  const marker = "/Sources/";
  const markerIndex = relativePath.indexOf(marker);
  if (markerIndex < 0) {
    return null;
  }

  return relativePath.slice(0, markerIndex + 1);
}

function sourceTreeGlobPattern(sourceTreePrefix: string | null): string {
  if (sourceTreePrefix === null) {
    return "**/Sources/**/*.swift";
  }
  return `${sourceTreePrefix}Sources/**/*.swift`;
}

function isPathInSourceTree(relativePath: string, sourceTreePrefix: string | null): boolean {
  const normalizedPath = normalizeFsPath(relativePath);
  if (sourceTreePrefix === null) {
    return normalizedPath.startsWith("Sources/") || normalizedPath.includes("/Sources/");
  }
  return normalizedPath.startsWith(`${sourceTreePrefix}Sources/`);
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
