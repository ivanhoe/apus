import * as fs from "fs/promises";
import * as path from "path";
import { createHash } from "crypto";

export const INDEX_SCHEMA_VERSION = 1;

export interface FileSymbolIndex {
  exports: string[];
  uses: string[];
}

export interface FileIndexEntry {
  relativePath: string;
  hash: string;
  size: number;
  mtimeMs: number;
  symbols: FileSymbolIndex;
  updatedAt: string;
}

export interface ProjectIndexSnapshot {
  version: number;
  workspaceRoot: string;
  generatedAt: string;
  files: Record<string, FileIndexEntry>;
}

export interface IndexStore {
  load(workspaceRoot: string): Promise<ProjectIndexSnapshot | null>;
  get(workspaceRoot: string, relativePath: string): Promise<FileIndexEntry | null>;
  upsert(workspaceRoot: string, entry: FileIndexEntry): Promise<ProjectIndexSnapshot>;
  upsertMany(workspaceRoot: string, entries: FileIndexEntry[]): Promise<ProjectIndexSnapshot>;
  save(workspaceRoot: string, snapshot: ProjectIndexSnapshot): Promise<void>;
}

export class FileIndexStore implements IndexStore {
  private readonly snapshotCache = new Map<string, ProjectIndexSnapshot>();
  private readonly writeLocks = new Map<string, Promise<unknown>>();

  private async serializePerWorkspace<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const previous = this.writeLocks.get(key) ?? Promise.resolve();
    const next = previous.then(fn, fn);
    this.writeLocks.set(key, next);
    try {
      return await next;
    } finally {
      if (this.writeLocks.get(key) === next) {
        this.writeLocks.delete(key);
      }
    }
  }

  async load(workspaceRoot: string): Promise<ProjectIndexSnapshot | null> {
    const key = normalizeWorkspaceRoot(workspaceRoot);
    const cached = this.snapshotCache.get(key);
    if (cached) {
      return cached;
    }

    const snapshotPath = this.snapshotPathForWorkspace(key);
    try {
      const raw = await fs.readFile(snapshotPath, "utf8");
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        return null;
      }
      const snapshot = validateSnapshot(parsed, key);
      if (!snapshot) {
        return null;
      }
      this.snapshotCache.set(key, snapshot);
      return snapshot;
    } catch (error: unknown) {
      if (isNodeError(error) && error.code === "ENOENT") {
        return null;
      }
      throw error;
    }
  }

  async get(workspaceRoot: string, relativePath: string): Promise<FileIndexEntry | null> {
    const snapshot = await this.load(workspaceRoot);
    if (!snapshot) {
      return null;
    }

    const key = normalizeRelativePath(relativePath);
    return snapshot.files[key] ?? null;
  }

  async upsert(workspaceRoot: string, entry: FileIndexEntry): Promise<ProjectIndexSnapshot> {
    return this.upsertMany(workspaceRoot, [entry]);
  }

  async upsertMany(workspaceRoot: string, entries: FileIndexEntry[]): Promise<ProjectIndexSnapshot> {
    const key = normalizeWorkspaceRoot(workspaceRoot);
    return this.serializePerWorkspace(key, async () => {
      const snapshot = (await this.load(key)) ?? createEmptySnapshot(key);
      const nextFiles = { ...snapshot.files };
      for (const entry of entries) {
        const normalizedPath = normalizeRelativePath(entry.relativePath);
        nextFiles[normalizedPath] = {
          ...entry,
          relativePath: normalizedPath,
        };
      }
      const next: ProjectIndexSnapshot = {
        ...snapshot,
        generatedAt: new Date().toISOString(),
        files: nextFiles,
      };
      await this.save(key, next);
      return next;
    });
  }

  async save(workspaceRoot: string, snapshot: ProjectIndexSnapshot): Promise<void> {
    const key = normalizeWorkspaceRoot(workspaceRoot);
    const snapshotPath = this.snapshotPathForWorkspace(key);
    await fs.mkdir(path.dirname(snapshotPath), { recursive: true });
    await fs.writeFile(snapshotPath, JSON.stringify(snapshot, null, 2), "utf8");
    this.snapshotCache.set(key, snapshot);
  }

  private snapshotPathForWorkspace(workspaceRoot: string): string {
    return path.join(workspaceRoot, ".apus", "cache", "index-v1.json");
  }
}

export function buildFileIndexEntry(input: {
  relativePath: string;
  content: string;
  size: number;
  mtimeMs: number;
}): FileIndexEntry {
  const relativePath = normalizeRelativePath(input.relativePath);
  const hash = sha256(input.content);
  const symbols = indexSwiftSymbols(input.content);
  return {
    relativePath,
    hash,
    size: input.size,
    mtimeMs: input.mtimeMs,
    symbols,
    updatedAt: new Date().toISOString(),
  };
}

function createEmptySnapshot(workspaceRoot: string): ProjectIndexSnapshot {
  return {
    version: INDEX_SCHEMA_VERSION,
    workspaceRoot: normalizeWorkspaceRoot(workspaceRoot),
    generatedAt: new Date().toISOString(),
    files: {},
  };
}

function validateSnapshot(parsed: unknown, workspaceRoot: string): ProjectIndexSnapshot | null {
  if (!isRecord(parsed)) {
    return null;
  }
  const version = typeof parsed.version === "number" ? parsed.version : -1;
  if (version !== INDEX_SCHEMA_VERSION) {
    return null;
  }

  const filesRaw = parsed.files;
  if (!isRecord(filesRaw)) {
    return null;
  }

  const files: Record<string, FileIndexEntry> = {};
  for (const [rawKey, value] of Object.entries(filesRaw)) {
    const key = normalizeRelativePath(rawKey);
    const entry = validateFileEntry(value, key);
    if (!entry) {
      continue;
    }
    files[key] = entry;
  }

  const generatedAt = typeof parsed.generatedAt === "string"
    ? parsed.generatedAt
    : new Date().toISOString();

  return {
    version: INDEX_SCHEMA_VERSION,
    workspaceRoot: normalizeWorkspaceRoot(workspaceRoot),
    generatedAt,
    files,
  };
}

function validateFileEntry(parsed: unknown, fallbackPath: string): FileIndexEntry | null {
  if (!isRecord(parsed)) {
    return null;
  }

  const relativePathRaw = typeof parsed.relativePath === "string" ? parsed.relativePath : fallbackPath;
  const relativePath = normalizeRelativePath(relativePathRaw);
  const hash = typeof parsed.hash === "string" ? parsed.hash : "";
  const size = typeof parsed.size === "number" ? parsed.size : 0;
  const mtimeMs = typeof parsed.mtimeMs === "number" ? parsed.mtimeMs : 0;
  const updatedAt = typeof parsed.updatedAt === "string" ? parsed.updatedAt : new Date().toISOString();
  const symbols = validateSymbolIndex(parsed.symbols);

  if (!relativePath || !hash) {
    return null;
  }

  return {
    relativePath,
    hash,
    size,
    mtimeMs,
    updatedAt,
    symbols,
  };
}

function validateSymbolIndex(parsed: unknown): FileSymbolIndex {
  if (!isRecord(parsed)) {
    return { exports: [], uses: [] };
  }

  const exports = Array.isArray(parsed.exports)
    ? parsed.exports.filter((item): item is string => typeof item === "string")
    : [];
  const uses = Array.isArray(parsed.uses)
    ? parsed.uses.filter((item): item is string => typeof item === "string")
    : [];

  return { exports, uses };
}

function indexSwiftSymbols(source: string): FileSymbolIndex {
  const exportPattern = /\b(struct|class|enum|protocol|actor|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)\b/g;
  const exportsSet = new Set<string>();
  let match: RegExpExecArray | null;
  while ((match = exportPattern.exec(source)) !== null) {
    if (match[2]) {
      exportsSet.add(match[2]);
    }
  }

  const usePattern = /\b[A-Z][A-Za-z0-9_]*\b/g;
  const usesSet = new Set<string>();
  while ((match = usePattern.exec(source)) !== null) {
    const candidate = match[0];
    if (!candidate || exportsSet.has(candidate)) {
      continue;
    }
    usesSet.add(candidate);
  }

  return {
    exports: Array.from(exportsSet).sort(),
    uses: Array.from(usesSet).sort(),
  };
}

function sha256(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function normalizeWorkspaceRoot(workspaceRoot: string): string {
  return path.resolve(workspaceRoot);
}

export function normalizeRelativePath(relativePath: string): string {
  return relativePath.replace(/\\/g, "/").replace(/^\.\/+/, "");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return typeof error === "object" && error !== null && "code" in error;
}
