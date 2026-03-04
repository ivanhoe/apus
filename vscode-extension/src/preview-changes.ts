import * as fs from "fs";
import * as path from "path";
import { spawn } from "child_process";
import * as vscode from "vscode";

const DEFAULT_SCRIPT_PATH = "ExampleApp/build-and-run.sh --deploy";
const DEFAULT_TIMEOUT_SECONDS = 600;
const GRACEFUL_KILL_TIMEOUT_MS = 5000;
const DEFAULT_AUTO_PREVIEW_COOLDOWN_SEC = 0;

type PreviewRunSource = "manual" | "auto";

export interface PreviewChangesCommandOptions {
  source?: PreviewRunSource;
  reason?: string;
  scriptPathOverride?: string;
}

interface PreviewChangesResult {
  timedOut: boolean;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  durationMs: number;
}

interface NormalizedPreviewOptions {
  source: PreviewRunSource;
  reason: string;
  scriptPathOverride?: string;
}

export function registerPreviewChangesCommand(
  context: vscode.ExtensionContext
): vscode.Disposable {
  const outputChannel = vscode.window.createOutputChannel("Apus Preview Changes");
  context.subscriptions.push(outputChannel);

  let runningPromise: Promise<void> | null = null;
  let queuedOptions: NormalizedPreviewOptions | null = null;
  let lastRunStartedAt = 0;

  const requestRun = async (rawOptions?: PreviewChangesCommandOptions): Promise<void> => {
    const options = normalizeOptions(rawOptions);

    if (runningPromise) {
      // Auto triggers: skip if something is already running or queued
      if (options.source === "auto") {
        outputChannel.appendLine(
          `[Apus] preview_changes already running; skipping auto trigger (${options.reason}).`
        );
        return runningPromise;
      }
      // Manual triggers: always queue, never overwritten by auto
      queuedOptions = options;
      outputChannel.appendLine(
        `[Apus] preview_changes already running; queued manual trigger (${options.reason}).`
      );
      return runningPromise;
    }

    runningPromise = runQueued(options).finally(() => {
      runningPromise = null;
    });
    return runningPromise;
  };

  const runQueued = async (initialOptions: NormalizedPreviewOptions): Promise<void> => {
    let current: NormalizedPreviewOptions | null = initialOptions;

    while (current) {
      if (current.source === "auto") {
        const cooldownMs = readAutoPreviewCooldownMs();
        const elapsedMs = Date.now() - lastRunStartedAt;
        const waitMs = Math.max(0, cooldownMs - elapsedMs);
        if (waitMs > 0) {
          outputChannel.appendLine(`[Apus] auto preview cooldown (${Math.ceil(waitMs / 1000)}s)`);
          await delay(waitMs);
        }
      }

      lastRunStartedAt = Date.now();
      await runPreviewOnce(current, outputChannel);

      const next = queuedOptions;
      queuedOptions = null;
      current = next;
    }
  };

  return vscode.commands.registerCommand("apus.previewChanges", async (rawOptions?: PreviewChangesCommandOptions) => {
    await requestRun(rawOptions);
  });
}

function normalizeTimeoutSeconds(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_TIMEOUT_SECONDS;
  }
  return Math.max(10, Math.floor(value));
}

function normalizeOptions(rawOptions?: PreviewChangesCommandOptions): NormalizedPreviewOptions {
  const source = rawOptions?.source === "auto" ? "auto" : "manual";
  const reasonRaw = rawOptions?.reason?.trim();
  const reason = reasonRaw && reasonRaw.length > 0
    ? reasonRaw
    : source === "auto"
      ? "auto-save"
      : "manual";

  const scriptPathOverride = rawOptions?.scriptPathOverride?.trim() || undefined;

  return { source, reason, scriptPathOverride };
}

async function runPreviewOnce(
  options: NormalizedPreviewOptions,
  outputChannel: vscode.OutputChannel
): Promise<void> {
  const config = vscode.workspace.getConfiguration("apus");
  const configuredScriptPath = options.scriptPathOverride
    || config.get<string>("previewChangesScriptPath", DEFAULT_SCRIPT_PATH)?.trim()
    || DEFAULT_SCRIPT_PATH;
  const configuredTimeoutSec = config.get<number>(
    "previewChangesTimeoutSec",
    DEFAULT_TIMEOUT_SECONDS
  );
  const revealOutputManual = config.get<boolean>("previewChangesRevealOutput", true);
  const revealOutputAuto = config.get<boolean>("autoPreviewRevealOutput", false);
  const autoSuccessToast = config.get<boolean>("autoPreviewShowSuccessNotification", false);

  const timeoutSec = normalizeTimeoutSeconds(configuredTimeoutSec);
  const scriptResolution = resolveScriptPath(configuredScriptPath);
  const scriptPath = scriptResolution.scriptPath;
  const scriptArgs = scriptResolution.scriptArgs;

  if (!scriptPath) {
    const attemptedPaths = scriptResolution.attemptedPaths.join("\n- ");
    const message = attemptedPaths.length > 0
      ? `Apus Preview Changes script not found. Tried:\n- ${attemptedPaths}`
      : "Apus Preview Changes script not found.";
    outputChannel.appendLine(`[Apus] ${message}`);
    void vscode.window.showErrorMessage(message);
    return;
  }

  const scriptDisplay = scriptArgs.length > 0
    ? `${scriptPath} ${scriptArgs.join(" ")}`
    : scriptPath;

  outputChannel.clear();
  outputChannel.appendLine("[Apus] preview_changes started");
  outputChannel.appendLine(`[Apus] source: ${options.source} (${options.reason})`);
  outputChannel.appendLine(`[Apus] script: ${scriptDisplay}`);
  outputChannel.appendLine(`[Apus] timeout: ${timeoutSec}s`);
  outputChannel.appendLine("");

  const revealOutput = options.source === "auto" ? revealOutputAuto : revealOutputManual;
  if (revealOutput) {
    outputChannel.show(true);
  }

  try {
    const result = await vscode.window.withProgress(
      {
        location: options.source === "auto"
          ? vscode.ProgressLocation.Window
          : vscode.ProgressLocation.Notification,
        title: "Apus: Preview Changes",
        cancellable: false,
      },
      async (progress) => {
        progress.report({ message: "Building and running ExampleApp..." });
        return executeScript({
          scriptPath,
          scriptArgs,
          timeoutMs: timeoutSec * 1000,
          outputChannel,
        });
      }
    );

    if (result.timedOut) {
      const message = `Apus preview_changes timed out after ${timeoutSec}s.`;
      outputChannel.appendLine(`[Apus] ${message}`);
      void vscode.window.showErrorMessage(message, "Show Output").then((action) => {
        if (action === "Show Output") { outputChannel.show(true); }
      });
      return;
    }

    if (result.exitCode === 0) {
      const seconds = formatDuration(result.durationMs);
      const message = `Apus preview_changes completed in ${seconds}s.`;
      outputChannel.appendLine(`[Apus] ${message}`);

      if (options.source === "manual" || autoSuccessToast) {
        void vscode.window.showInformationMessage(message, "Show Output").then((action) => {
          if (action === "Show Output") {
            outputChannel.show(true);
          }
        });
      }
      return;
    }

    const exitOrSignal = result.signal
      ? `signal ${result.signal}`
      : `exit code ${result.exitCode ?? "unknown"}`;
    const message = `Apus preview_changes failed (${exitOrSignal}).`;
    outputChannel.appendLine(`[Apus] ${message}`);
    void vscode.window.showErrorMessage(message, "Show Output").then((action) => {
      if (action === "Show Output") { outputChannel.show(true); }
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    outputChannel.appendLine(`[Apus] preview_changes crashed: ${message}`);
    void vscode.window.showErrorMessage(
      `Apus preview_changes failed to start: ${message}`,
      "Show Output"
    ).then((action) => {
      if (action === "Show Output") { outputChannel.show(true); }
    });
  }
}

function formatDuration(durationMs: number): string {
  return (durationMs / 1000).toFixed(1);
}

function readAutoPreviewCooldownMs(): number {
  const config = vscode.workspace.getConfiguration("apus");
  const cooldownSec = config.get<number>(
    "autoPreviewCooldownSec",
    DEFAULT_AUTO_PREVIEW_COOLDOWN_SEC
  );
  if (typeof cooldownSec !== "number" || !Number.isFinite(cooldownSec)) {
    return DEFAULT_AUTO_PREVIEW_COOLDOWN_SEC * 1000;
  }
  return Math.max(0, Math.floor(cooldownSec * 1000));
}

function resolveScriptPath(configuredScriptPath: string): {
  scriptPath: string | null;
  scriptArgs: string[];
  attemptedPaths: string[];
} {
  const attemptedPaths: string[] = [];

  // Split "script.sh --flag" into path + args while respecting quotes.
  const parsedParts = parseShellLikeArgs(configuredScriptPath);
  const parts = parsedParts ?? configuredScriptPath.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) {
    return { scriptPath: null, scriptArgs: [], attemptedPaths };
  }

  const scriptFile = parts[0];
  const scriptArgs = parts.slice(1);

  if (path.isAbsolute(scriptFile)) {
    attemptedPaths.push(scriptFile);
    return {
      scriptPath: fs.existsSync(scriptFile) ? scriptFile : null,
      scriptArgs,
      attemptedPaths,
    };
  }

  const workspaceFolders = vscode.workspace.workspaceFolders ?? [];
  for (const folder of workspaceFolders) {
    const basePath = folder.uri.fsPath;
    const directCandidate = path.join(basePath, scriptFile);
    attemptedPaths.push(directCandidate);
    if (fs.existsSync(directCandidate)) {
      return { scriptPath: directCandidate, scriptArgs, attemptedPaths };
    }

    // Useful when the extension folder is opened as workspace root.
    const siblingCandidate = path.join(basePath, "..", scriptFile);
    if (!attemptedPaths.includes(siblingCandidate)) {
      attemptedPaths.push(siblingCandidate);
      if (fs.existsSync(siblingCandidate)) {
        return { scriptPath: siblingCandidate, scriptArgs, attemptedPaths };
      }
    }
  }

  return { scriptPath: null, scriptArgs, attemptedPaths };
}

function parseShellLikeArgs(value: string): string[] | null {
  const args: string[] = [];
  let current = "";
  let quote: "'" | "\"" | null = null;
  let escaped = false;

  for (const ch of value.trim()) {
    if (escaped) {
      current += ch;
      escaped = false;
      continue;
    }

    if (ch === "\\") {
      if (quote === "'") {
        current += ch;
      } else {
        escaped = true;
      }
      continue;
    }

    if (quote) {
      if (ch === quote) {
        quote = null;
      } else {
        current += ch;
      }
      continue;
    }

    if (ch === "'" || ch === "\"") {
      quote = ch;
      continue;
    }

    if (/\s/.test(ch)) {
      if (current.length > 0) {
        args.push(current);
        current = "";
      }
      continue;
    }

    current += ch;
  }

  if (escaped) {
    current += "\\";
  }

  // Fallback to legacy whitespace split when a quote is left open.
  if (quote) {
    return null;
  }

  if (current.length > 0) {
    args.push(current);
  }

  return args;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, Math.max(0, ms));
  });
}

function executeScript(options: {
  scriptPath: string;
  scriptArgs?: string[];
  timeoutMs: number;
  outputChannel: vscode.OutputChannel;
}): Promise<PreviewChangesResult> {
  const { scriptPath, scriptArgs = [], timeoutMs, outputChannel } = options;

  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const child = spawn("/bin/bash", [scriptPath, ...scriptArgs], {
      cwd: path.dirname(scriptPath),
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let timedOut = false;
    let exited = false;
    let killFallbackTimer: NodeJS.Timeout | undefined;
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      outputChannel.appendLine(`[Apus] timeout reached (${Math.floor(timeoutMs / 1000)}s), sending SIGTERM...`);
      child.kill("SIGTERM");
      killFallbackTimer = setTimeout(() => {
        if (!exited) {
          outputChannel.appendLine("[Apus] process did not exit after SIGTERM, sending SIGKILL...");
          child.kill("SIGKILL");
        }
      }, GRACEFUL_KILL_TIMEOUT_MS);
    }, timeoutMs);

    child.stdout.on("data", (chunk: Buffer) => {
      outputChannel.append(chunk.toString("utf8"));
    });

    child.stderr.on("data", (chunk: Buffer) => {
      outputChannel.append(chunk.toString("utf8"));
    });

    child.on("error", (error) => {
      clearTimeout(timeoutTimer);
      if (killFallbackTimer) {
        clearTimeout(killFallbackTimer);
      }
      reject(error);
    });

    child.on("close", (exitCode, signal) => {
      exited = true;
      clearTimeout(timeoutTimer);
      if (killFallbackTimer) {
        clearTimeout(killFallbackTimer);
      }

      resolve({
        timedOut,
        exitCode,
        signal,
        durationMs: Date.now() - startedAt,
      });
    });
  });
}
