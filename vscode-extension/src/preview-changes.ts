import * as fs from "fs";
import * as path from "path";
import { spawn } from "child_process";
import * as vscode from "vscode";

const DEFAULT_SCRIPT_PATH = "ExampleApp/build-and-run.sh";
const DEFAULT_TIMEOUT_SECONDS = 600;
const GRACEFUL_KILL_TIMEOUT_MS = 5000;

interface PreviewChangesResult {
  timedOut: boolean;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  durationMs: number;
}

export function registerPreviewChangesCommand(
  context: vscode.ExtensionContext
): vscode.Disposable {
  const outputChannel = vscode.window.createOutputChannel("Apus Preview Changes");
  context.subscriptions.push(outputChannel);

  return vscode.commands.registerCommand("apus.previewChanges", async () => {
    const workspaceRoot = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (!workspaceRoot) {
      void vscode.window.showErrorMessage(
        "Apus Preview Changes requires an open workspace folder."
      );
      return;
    }

    const config = vscode.workspace.getConfiguration("apus");
    const configuredScriptPath = config.get<string>(
      "previewChangesScriptPath",
      DEFAULT_SCRIPT_PATH
    )?.trim() || DEFAULT_SCRIPT_PATH;
    const configuredTimeoutSec = config.get<number>(
      "previewChangesTimeoutSec",
      DEFAULT_TIMEOUT_SECONDS
    );
    const revealOutput = config.get<boolean>("previewChangesRevealOutput", true);

    const scriptPath = path.isAbsolute(configuredScriptPath)
      ? configuredScriptPath
      : path.join(workspaceRoot, configuredScriptPath);
    const timeoutSec = normalizeTimeoutSeconds(configuredTimeoutSec);

    if (!fs.existsSync(scriptPath)) {
      void vscode.window.showErrorMessage(
        `Apus Preview Changes script not found: ${scriptPath}`
      );
      return;
    }

    outputChannel.clear();
    outputChannel.appendLine("[Apus] preview_changes started");
    outputChannel.appendLine(`[Apus] script: ${scriptPath}`);
    outputChannel.appendLine(`[Apus] timeout: ${timeoutSec}s`);
    outputChannel.appendLine("");

    if (revealOutput) {
      outputChannel.show(true);
    }

    try {
      const result = await vscode.window.withProgress(
        {
          location: vscode.ProgressLocation.Notification,
          title: "Apus: Preview Changes",
          cancellable: false,
        },
        async (progress) => {
          progress.report({ message: "Building and running ExampleApp..." });
          return executeScript({
            scriptPath,
            timeoutMs: timeoutSec * 1000,
            outputChannel,
          });
        }
      );

      if (result.timedOut) {
        const message = `Apus preview_changes timed out after ${timeoutSec}s.`;
        outputChannel.appendLine(`[Apus] ${message}`);
        const action = await vscode.window.showErrorMessage(message, "Show Output");
        if (action === "Show Output") {
          outputChannel.show(true);
        }
        return;
      }

      if (result.exitCode === 0) {
        const seconds = formatDuration(result.durationMs);
        const message = `Apus preview_changes completed in ${seconds}s.`;
        outputChannel.appendLine(`[Apus] ${message}`);
        const action = await vscode.window.showInformationMessage(
          message,
          "Show Output"
        );
        if (action === "Show Output") {
          outputChannel.show(true);
        }
        return;
      }

      const exitOrSignal = result.signal
        ? `signal ${result.signal}`
        : `exit code ${result.exitCode ?? "unknown"}`;
      const message = `Apus preview_changes failed (${exitOrSignal}).`;
      outputChannel.appendLine(`[Apus] ${message}`);
      const action = await vscode.window.showErrorMessage(message, "Show Output");
      if (action === "Show Output") {
        outputChannel.show(true);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      outputChannel.appendLine(`[Apus] preview_changes crashed: ${message}`);
      const action = await vscode.window.showErrorMessage(
        `Apus preview_changes failed to start: ${message}`,
        "Show Output"
      );
      if (action === "Show Output") {
        outputChannel.show(true);
      }
    }
  });
}

function normalizeTimeoutSeconds(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_TIMEOUT_SECONDS;
  }
  return Math.max(10, Math.floor(value));
}

function formatDuration(durationMs: number): string {
  return (durationMs / 1000).toFixed(1);
}

function executeScript(options: {
  scriptPath: string;
  timeoutMs: number;
  outputChannel: vscode.OutputChannel;
}): Promise<PreviewChangesResult> {
  const { scriptPath, timeoutMs, outputChannel } = options;

  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const child = spawn("/bin/bash", [scriptPath], {
      cwd: path.dirname(scriptPath),
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let timedOut = false;
    let killFallbackTimer: NodeJS.Timeout | undefined;
    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      outputChannel.appendLine(`[Apus] timeout reached (${Math.floor(timeoutMs / 1000)}s), sending SIGTERM...`);
      child.kill("SIGTERM");
      killFallbackTimer = setTimeout(() => {
        if (!child.killed) {
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
