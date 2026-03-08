import { ApusClient } from "../apus-client";
import { extractToolResultText, isToolResultError } from "../mcp-tool-result";

const DEFAULT_HIERARCHY_DEPTH = 24;
const DEFAULT_HIERARCHY_CACHE_MS = 300;
export const UNCHANGED_TOOL_RESPONSE = "(unchanged since last call)";
const HIERARCHY_PROBE_DEPTHS = [8, 12] as const;
const HIERARCHY_RETRY_BACKOFF_MS = [0, 120, 260] as const;
const HIERARCHY_TOOL_TIMEOUT_MS = 25_000;

interface ToolTextContent {
  type: string;
  text?: string;
}

interface Coordinate {
  x: number;
  y: number;
}

interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface ContentOffset {
  x: number;
  y: number;
}

interface HierarchyNode {
  className: string;
  path: string;
  frame: Frame;
  properties: {
    hidden?: boolean;
    alpha?: number;
    userInteractionEnabled?: boolean;
    accessibilityIdentifier?: string;
    accessibilityLabel?: string;
    contentOffset?: ContentOffset;
  };
  subviews: HierarchyNode[];
}

interface LocatedNode {
  node: HierarchyNode;
  absFrame: Frame;
}

export type HierarchyTargetMode = "identifier" | "label" | "path";

export interface ResolvedHierarchyTarget {
  mode: HierarchyTargetMode;
  detail: string;
  frame: Frame;
}

export interface ResolvedInteractionArgs {
  args: Record<string, unknown>;
  usedHierarchyTargeting: boolean;
  target: ResolvedHierarchyTarget | null;
}

export interface ResolveInteractionOptions {
  allowPathTarget?: boolean;
}

export class InteractionTargetResolver {
  private cachedHierarchy: HierarchyNode | null = null;
  private cachedAt = 0;
  private inFlightHierarchy: Promise<HierarchyNode | null> | null = null;

  constructor(
    private readonly client: ApusClient,
    private readonly hierarchyDepth = DEFAULT_HIERARCHY_DEPTH,
    private readonly cacheMs = DEFAULT_HIERARCHY_CACHE_MS
  ) {}

  invalidate(): void {
    this.cachedHierarchy = null;
    this.cachedAt = 0;
  }

  async resolve(
    args: Record<string, unknown>,
    options: ResolveInteractionOptions = {}
  ): Promise<ResolvedInteractionArgs> {
    if (!isCoordinateOnlyInteraction(args)) {
      return { args, usedHierarchyTargeting: false, target: null };
    }

    const allowPathTarget = options.allowPathTarget ?? true;
    const coord = readCoordinate(args.coordinate);
    if (!coord) {
      return { args, usedHierarchyTargeting: false, target: null };
    }

    const hierarchy = await this.getHierarchy();
    if (!hierarchy) {
      return { args, usedHierarchyTargeting: false, target: null };
    }

    const hitPath = findHitPath(hierarchy, coord, 0, 0);
    if (!hitPath || hitPath.length === 0) {
      return { args, usedHierarchyTargeting: false, target: null };
    }

    const target = selectTargetFromPath(hitPath, allowPathTarget);
    if (!target) {
      return { args, usedHierarchyTargeting: false, target: null };
    }

    const nextArgs: Record<string, unknown> = { ...args, ...target.args };
    delete nextArgs.coordinate;

    return { args: nextArgs, usedHierarchyTargeting: true, target: target.resolved };
  }

  private async getHierarchy(): Promise<HierarchyNode | null> {
    const now = Date.now();
    if (this.cachedHierarchy && now - this.cachedAt <= this.cacheMs) {
      return this.cachedHierarchy;
    }

    if (this.inFlightHierarchy) {
      return this.inFlightHierarchy;
    }

    this.inFlightHierarchy = this.fetchHierarchy().finally(() => {
      this.inFlightHierarchy = null;
    });

    const hierarchy = await this.inFlightHierarchy;
    if (hierarchy) {
      this.cachedHierarchy = hierarchy;
      this.cachedAt = Date.now();
    }

    return hierarchy;
  }

  private async fetchHierarchy(): Promise<HierarchyNode | null> {
    const depthPlan = this.hierarchyRequestDepthPlan();

    for (let attempt = 0; attempt < depthPlan.length; attempt++) {
      const depth = depthPlan[attempt];
      const cacheBust = attempt > 0 ? Date.now() + attempt : undefined;
      const initialResponse = await this.fetchHierarchyText(depth, cacheBust);

      if (initialResponse.error || !initialResponse.text) {
        await this.waitBeforeRetry(attempt, depthPlan.length);
        continue;
      }

      let text = initialResponse.text;
      if (isUnchangedToolResponse(text)) {
        if (this.cachedHierarchy) {
          return this.cachedHierarchy;
        }

        const forcedFreshResponse = await this.fetchHierarchyText(depth, Date.now() + attempt + 1);
        if (forcedFreshResponse.error || !forcedFreshResponse.text) {
          await this.waitBeforeRetry(attempt, depthPlan.length);
          continue;
        }
        text = forcedFreshResponse.text;
      }

      if (isUnchangedToolResponse(text)) {
        await this.waitBeforeRetry(attempt, depthPlan.length);
        continue;
      }

      try {
        const parsed = JSON.parse(text) as unknown;
        const hierarchy = parseHierarchyNode(parsed);
        if (hierarchy) {
          return hierarchy;
        }
      } catch {
        // Continue to next attempt with deeper traversal and backoff.
      }

      await this.waitBeforeRetry(attempt, depthPlan.length);
    }

    return this.cachedHierarchy;
  }

  private hierarchyRequestDepthPlan(): number[] {
    const uniqueDepths = new Set<number>([
      ...HIERARCHY_PROBE_DEPTHS,
      this.hierarchyDepth,
    ]);

    return Array.from(uniqueDepths)
      .filter((depth) => Number.isFinite(depth) && depth > 0)
      .sort((left, right) => left - right);
  }

  private async waitBeforeRetry(attempt: number, totalAttempts: number): Promise<void> {
    if (attempt >= totalAttempts - 1) {
      return;
    }

    const backoff = HIERARCHY_RETRY_BACKOFF_MS[
      Math.min(attempt, HIERARCHY_RETRY_BACKOFF_MS.length - 1)
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
        { timeoutMs: HIERARCHY_TOOL_TIMEOUT_MS }
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
}

export { extractToolResultText, isToolResultError };

export function isUnchangedToolResponse(text: string): boolean {
  return text.trim() === UNCHANGED_TOOL_RESPONSE;
}

export function isCoordinateOnlyInteraction(args: Record<string, unknown>): boolean {
  const action = typeof args.action === "string" ? args.action : "";
  if (
    action !== "tap" &&
    action !== "double_tap" &&
    action !== "long_press" &&
    action !== "swipe"
  ) {
    return false;
  }

  if (hasNonEmptyString(args.identifier) || hasNonEmptyString(args.label) || hasNonEmptyString(args.path)) {
    return false;
  }

  return true;
}

function readCoordinate(value: unknown): Coordinate | null {
  if (!isRecord(value)) {
    return null;
  }

  const x = typeof value.x === "number" ? value.x : NaN;
  const y = typeof value.y === "number" ? value.y : NaN;
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return null;
  }

  return { x, y };
}

function parseHierarchyNode(value: unknown): HierarchyNode | null {
  if (!isRecord(value)) {
    return null;
  }

  const className = typeof value.className === "string" ? value.className : "";
  const path = typeof value.path === "string" ? value.path : "";
  const frame = parseFrame(value.frame);
  const properties = parseProperties(value.properties);
  if (!className || !frame || !properties) {
    return null;
  }

  const rawSubviews = Array.isArray(value.subviews) ? value.subviews : [];
  const subviews: HierarchyNode[] = [];
  for (const subview of rawSubviews) {
    const parsed = parseHierarchyNode(subview);
    if (parsed) {
      subviews.push(parsed);
    }
  }

  return { className, path, frame, properties, subviews };
}

function parseFrame(value: unknown): Frame | null {
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
}

function parseProperties(value: unknown): HierarchyNode["properties"] | null {
  if (!isRecord(value)) {
    return null;
  }

  const properties: HierarchyNode["properties"] = {};
  if (typeof value.hidden === "boolean") {
    properties.hidden = value.hidden;
  }
  if (typeof value.alpha === "number" && Number.isFinite(value.alpha)) {
    properties.alpha = value.alpha;
  }
  if (typeof value.userInteractionEnabled === "boolean") {
    properties.userInteractionEnabled = value.userInteractionEnabled;
  }
  if (typeof value.accessibilityIdentifier === "string") {
    properties.accessibilityIdentifier = value.accessibilityIdentifier;
  }
  if (typeof value.accessibilityLabel === "string") {
    properties.accessibilityLabel = value.accessibilityLabel;
  }

  const contentOffset = parseContentOffset(value.contentOffset);
  if (contentOffset) {
    properties.contentOffset = contentOffset;
  }

  return properties;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, Math.max(0, ms));
  });
}

function parseContentOffset(value: unknown): ContentOffset | null {
  if (!isRecord(value)) {
    return null;
  }

  const x = typeof value.x === "number" ? value.x : NaN;
  const y = typeof value.y === "number" ? value.y : NaN;
  if (!Number.isFinite(x) || !Number.isFinite(y)) {
    return null;
  }

  return { x, y };
}

function findHitPath(
  node: HierarchyNode,
  coordinate: Coordinate,
  parentAbsX: number,
  parentAbsY: number
): LocatedNode[] | null {
  if (node.properties.hidden) {
    return null;
  }
  if (typeof node.properties.alpha === "number" && node.properties.alpha <= 0.01) {
    return null;
  }

  const absX = parentAbsX + node.frame.x;
  const absY = parentAbsY + node.frame.y;
  const width = Math.max(0, node.frame.width);
  const height = Math.max(0, node.frame.height);

  if (width <= 0 || height <= 0) {
    return null;
  }

  if (!pointInRect(coordinate, absX, absY, width, height)) {
    return null;
  }

  const currentFrame: Frame = {
    x: absX,
    y: absY,
    width,
    height,
  };
  const current: LocatedNode = { node, absFrame: currentFrame };

  const offset = node.properties.contentOffset;
  const childParentX = offset ? absX - offset.x : absX;
  const childParentY = offset ? absY - offset.y : absY;

  for (let i = node.subviews.length - 1; i >= 0; i--) {
    const child = node.subviews[i];
    const childPath = findHitPath(child, coordinate, childParentX, childParentY);
    if (childPath) {
      return [current, ...childPath];
    }
  }

  return [current];
}

function selectTargetFromPath(
  path: LocatedNode[],
  allowPathTarget: boolean
): {
  args: Record<string, unknown>;
  resolved: ResolvedHierarchyTarget;
} | null {
  for (let i = path.length - 1; i >= 0; i--) {
    const node = path[i].node;
    if (node.properties.userInteractionEnabled === false) {
      continue;
    }

    const identifier = readNonEmptyString(node.properties.accessibilityIdentifier);
    if (identifier) {
      return {
        args: { identifier },
        resolved: { mode: "identifier", detail: identifier, frame: path[i].absFrame },
      };
    }

    const label = readNonEmptyString(node.properties.accessibilityLabel);
    if (label) {
      return {
        args: { label },
        resolved: { mode: "label", detail: label, frame: path[i].absFrame },
      };
    }

    if (allowPathTarget && node.path && isLikelyInteractiveClassName(node.className)) {
      return {
        args: { path: node.path },
        resolved: { mode: "path", detail: node.path, frame: path[i].absFrame },
      };
    }
  }

  return null;
}

function isLikelyInteractiveClassName(className: string): boolean {
  const value = className.toLowerCase();
  return (
    value.includes("button") ||
    value.includes("control") ||
    value.includes("cell") ||
    value.includes("switch") ||
    value.includes("slider") ||
    value.includes("textfield") ||
    value.includes("textview") ||
    value.includes("searchbar") ||
    value.includes("stepper") ||
    value.includes("segmented") ||
    value.includes("tabbar") ||
    value.includes("navigation") ||
    value.includes("scrollview")
  );
}

export function describeCoordinateTarget(args: Record<string, unknown>): string | undefined {
  const coord = readCoordinate(args.coordinate);
  if (!coord) {
    return undefined;
  }
  return `(${Math.round(coord.x)}, ${Math.round(coord.y)})`;
}

function pointInRect(point: Coordinate, x: number, y: number, width: number, height: number): boolean {
  return point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height;
}

function hasNonEmptyString(value: unknown): boolean {
  return readNonEmptyString(value) !== null;
}

function readNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
