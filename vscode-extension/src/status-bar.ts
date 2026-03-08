import * as vscode from "vscode";
import { ConnectionState } from "./types";

export type ApplyIndicatorState = "idle" | "running" | "success" | "failed";

/**
 * Manages the Apus status bar item showing connection state.
 *
 * States:
 * - Connected:    $(check) Apus — click to show Inspector
 * - Connecting:   $(sync~spin) Apus — shows spinner
 * - Disconnected: $(debug-disconnect) Apus — click to reconnect
 */
export class StatusBar implements vscode.Disposable {
  private item: vscode.StatusBarItem;
  private deployItem: vscode.StatusBarItem;
  private applyItem: vscode.StatusBarItem;
  private applyResetTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    this.item = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      50
    );
    this.update("disconnected");
    this.item.show();

    this.deployItem = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      49
    );
    this.deployItem.text = "$(rocket) Deploy";
    const shortcut = process.platform === "darwin" ? "Cmd+Shift+R" : "Ctrl+Shift+R";
    this.deployItem.tooltip = `Apus: Preview Changes (${shortcut})`;
    this.deployItem.command = "apus.previewChanges";
    this.deployItem.show();

    this.applyItem = vscode.window.createStatusBarItem(
      vscode.StatusBarAlignment.Left,
      48
    );
    this.applyItem.command = "apus.showAutoApplyOutput";
    this.updateApply("idle");
    this.applyItem.show();
  }

  /** Update display based on connection state. */
  update(state: ConnectionState, serverName?: string): void {
    const label = serverName ?? "Apus";

    switch (state) {
      case "connected":
        this.item.text = `$(check) ${label}`;
        this.item.tooltip = `Connected to ${label} — click to show Inspector`;
        this.item.command = "apus.showInspector";
        this.item.backgroundColor = undefined;
        break;
      case "connecting":
        this.item.text = `$(sync~spin) ${label}`;
        this.item.tooltip = "Connecting to Apus...";
        this.item.command = undefined;
        this.item.backgroundColor = undefined;
        break;
      case "disconnected":
        this.item.text = `$(debug-disconnect) ${label}`;
        this.item.tooltip = "Disconnected — click to reconnect";
        this.item.command = "apus.connect";
        this.item.backgroundColor = new vscode.ThemeColor(
          "statusBarItem.warningBackground"
        );
        break;
    }
  }

  updateApply(state: ApplyIndicatorState, detail = "idle"): void {
    if (this.applyResetTimer) {
      clearTimeout(this.applyResetTimer);
      this.applyResetTimer = null;
    }

    switch (state) {
      case "idle":
        this.applyItem.text = "$(history) Apply: idle";
        this.applyItem.tooltip = "Apus auto apply is idle";
        this.applyItem.backgroundColor = undefined;
        break;
      case "running":
        this.applyItem.text = `$(sync~spin) Apply: ${detail}`;
        this.applyItem.tooltip = "Apus auto apply is running";
        this.applyItem.backgroundColor = undefined;
        break;
      case "success":
        this.applyItem.text = `$(check) Apply: ${detail}`;
        this.applyItem.tooltip = "Apus auto apply completed successfully";
        this.applyItem.backgroundColor = undefined;
        this.applyResetTimer = setTimeout(() => this.updateApply("idle"), 4000);
        break;
      case "failed":
        this.applyItem.text = `$(error) Apply: ${detail}`;
        this.applyItem.tooltip = "Apus auto apply failed";
        this.applyItem.backgroundColor = new vscode.ThemeColor(
          "statusBarItem.errorBackground"
        );
        this.applyResetTimer = setTimeout(() => this.updateApply("idle"), 6000);
        break;
    }
  }

  dispose(): void {
    if (this.applyResetTimer) {
      clearTimeout(this.applyResetTimer);
      this.applyResetTimer = null;
    }
    this.item.dispose();
    this.deployItem.dispose();
    this.applyItem.dispose();
  }
}
