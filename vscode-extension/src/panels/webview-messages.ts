import { match, P } from "ts-pattern";
import { ConnectionState, LogEntry, NetworkEntry } from "../types";

export type InteractionTargetMode =
  | "identifier"
  | "label"
  | "path"
  | "coordinate"
  | "fallback";

export interface InteractionTargetFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface LivePreviewInteractMessage {
  type: "interact";
  id: number;
  args: Record<string, unknown>;
}

export type LivePreviewInboundMessage =
  | LivePreviewInteractMessage
  | { type: "pauseStream" }
  | { type: "resumeStream" }
  | { type: "requestHierarchy" }
  | { type: "previewChanges" };

export type LivePreviewOutboundMessage =
  | { type: "screenshot"; data: string; seq: number }
  | { type: "connectionState"; state: ConnectionState }
  | { type: "config"; scale: number }
  | { type: "streamState"; paused: boolean; mode: "active" | "idle"; targetFps: number }
  | {
      type: "interactResult";
      id: number;
      text: string;
      targetMode?: InteractionTargetMode;
      targetDetail?: string;
      targetFrame?: InteractionTargetFrame;
    }
  | {
      type: "interactResult";
      id: number;
      error: string;
      targetMode?: InteractionTargetMode;
      targetDetail?: string;
      targetFrame?: InteractionTargetFrame;
    };

export type LogViewerInboundMessage =
  | { type: "pause" }
  | { type: "resume" }
  | { type: "clear" }
  | { type: "export" };

export type LogViewerOutboundMessage =
  | { type: "log"; entry: LogEntry }
  | { type: "bulk"; entries: LogEntry[] }
  | { type: "connectionState"; state: ConnectionState };

export type InspectorOutboundMessage =
  | { type: "screenshot"; data: string; seq: number }
  | { type: "hierarchy"; hierarchy: Record<string, unknown> | null; error?: string }
  | { type: "connectionState"; state: ConnectionState }
  | { type: "config"; scale: number }
  | { type: "streamState"; paused: boolean; mode: "active" | "idle"; targetFps: number }
  | {
      type: "interactResult";
      id: number;
      text: string;
      targetMode?: InteractionTargetMode;
      targetDetail?: string;
      targetFrame?: InteractionTargetFrame;
    }
  | {
      type: "interactResult";
      id: number;
      error: string;
      targetMode?: InteractionTargetMode;
      targetDetail?: string;
      targetFrame?: InteractionTargetFrame;
    }
  | { type: "log"; entry: LogEntry }
  | { type: "bulkLogs"; entries: LogEntry[] }
  | { type: "network"; entry: NetworkEntry }
  | { type: "bulkNetwork"; entries: NetworkEntry[] };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseLivePreviewInboundMessage(
  value: unknown
): LivePreviewInboundMessage | null {
  if (!isRecord(value)) {
    return null;
  }

  return match(value)
    .with(
      {
        type: "interact",
        id: P.number,
        args: P.when((args) => isRecord(args)),
      },
      (msg) => ({
        type: "interact",
        id: msg.id,
        args: msg.args,
      })
    )
    .with({ type: "pauseStream" }, () => ({ type: "pauseStream" as const }))
    .with({ type: "resumeStream" }, () => ({ type: "resumeStream" as const }))
    .with({ type: "requestHierarchy" }, () => ({ type: "requestHierarchy" as const }))
    .with({ type: "previewChanges" }, () => ({ type: "previewChanges" as const }))
    .otherwise(() => null);
}

export function parseLogViewerInboundMessage(
  value: unknown
): LogViewerInboundMessage | null {
  if (!isRecord(value)) {
    return null;
  }

  return match(value)
    .with({ type: "pause" }, () => ({ type: "pause" as const }))
    .with({ type: "resume" }, () => ({ type: "resume" as const }))
    .with({ type: "clear" }, () => ({ type: "clear" as const }))
    .with({ type: "export" }, () => ({ type: "export" as const }))
    .otherwise(() => null);
}
