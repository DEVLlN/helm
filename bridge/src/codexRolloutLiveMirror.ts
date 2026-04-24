import { stat } from "node:fs/promises";

import type { ThreadSummary } from "./types.js";

type FileStats = {
  size: number;
  mtimeMs: number;
};

export type CodexRolloutMirrorChange = {
  threadId: string;
  summary: ThreadSummary;
  rolloutPath: string;
  reason: "bootstrap" | "changed";
  size: number;
  mtimeMs: number;
};

type MirrorRecord = {
  threadId: string;
  summary: ThreadSummary;
  rolloutPath: string;
  size: number;
  mtimeMs: number;
  lastTouchedAt: number;
};

export type CodexRolloutLiveMirrorController = {
  observeThread(summary: ThreadSummary): Promise<boolean>;
  poll(): Promise<void>;
  stopThread(threadId: string): void;
  stopAll(): void;
  activeThreadIds(): string[];
};

export function createCodexRolloutLiveMirrorController({
  resolveRolloutPath,
  onRolloutChanged,
  now = () => Date.now(),
  statFile = async (filePath: string) => stat(filePath),
  idleTimeoutMs = 2 * 60 * 1000,
  maxMirrors = 8,
}: {
  resolveRolloutPath: (threadId: string) => Promise<string | null>;
  onRolloutChanged: (change: CodexRolloutMirrorChange) => Promise<void>;
  now?: () => number;
  statFile?: (filePath: string) => Promise<FileStats>;
  idleTimeoutMs?: number;
  maxMirrors?: number;
}): CodexRolloutLiveMirrorController {
  const records = new Map<string, MirrorRecord>();

  async function observeThread(summary: ThreadSummary): Promise<boolean> {
    if (!isCodexRolloutMirrorEligibleSummary(summary)) {
      return false;
    }

    const threadId = summary.id;
    const rolloutPath = await resolveRolloutPath(threadId);
    if (!rolloutPath) {
      records.delete(threadId);
      return false;
    }

    const stats = await statFile(rolloutPath);
    const existing = records.get(threadId);
    const currentTime = now();
    records.set(threadId, {
      threadId,
      summary,
      rolloutPath,
      size: stats.size,
      mtimeMs: stats.mtimeMs,
      lastTouchedAt: currentTime,
    });
    trimOldestIfNeeded();

    const changed =
      !existing
      || existing.rolloutPath !== rolloutPath
      || existing.size !== stats.size
      || existing.mtimeMs !== stats.mtimeMs;
    if (changed) {
      await onRolloutChanged({
        threadId,
        summary,
        rolloutPath,
        reason: existing ? "changed" : "bootstrap",
        size: stats.size,
        mtimeMs: stats.mtimeMs,
      });
    }

    return true;
  }

  async function poll(): Promise<void> {
    const currentTime = now();
    for (const [threadId, record] of Array.from(records.entries())) {
      if (currentTime - record.lastTouchedAt > idleTimeoutMs) {
        records.delete(threadId);
        continue;
      }

      let stats: FileStats;
      try {
        stats = await statFile(record.rolloutPath);
      } catch {
        records.delete(threadId);
        continue;
      }

      if (stats.size === record.size && stats.mtimeMs === record.mtimeMs) {
        continue;
      }

      const updatedRecord = {
        ...record,
        size: stats.size,
        mtimeMs: stats.mtimeMs,
        lastTouchedAt: currentTime,
      };
      records.set(threadId, updatedRecord);
      await onRolloutChanged({
        threadId,
        summary: updatedRecord.summary,
        rolloutPath: updatedRecord.rolloutPath,
        reason: "changed",
        size: stats.size,
        mtimeMs: stats.mtimeMs,
      });
    }
  }

  function stopThread(threadId: string): void {
    records.delete(threadId);
  }

  function stopAll(): void {
    records.clear();
  }

  function activeThreadIds(): string[] {
    return Array.from(records.keys());
  }

  function trimOldestIfNeeded(): void {
    while (records.size > maxMirrors) {
      const oldest = Array.from(records.values())
        .sort((lhs, rhs) => lhs.lastTouchedAt - rhs.lastTouchedAt)[0];
      if (!oldest) {
        return;
      }
      records.delete(oldest.threadId);
    }
  }

  return {
    observeThread,
    poll,
    stopThread,
    stopAll,
    activeThreadIds,
  };
}

export function isCodexRolloutMirrorEligibleSummary(summary: ThreadSummary): boolean {
  const backendId = summary.backendId.trim().toLowerCase();
  const backendKind = summary.backendKind.trim().toLowerCase();
  if (backendId === "codex" || backendKind === "codex") {
    return true;
  }

  const sourceKind = (summary.sourceKind ?? "").trim().toLowerCase();
  return sourceKind === "vscode" || sourceKind === "appserver" || sourceKind === "cli";
}
