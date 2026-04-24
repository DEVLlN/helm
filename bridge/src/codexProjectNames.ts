import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

type CodexGlobalState = {
  "electron-workspace-root-labels"?: Record<string, unknown>;
};

let cachedLabels: Map<string, string> | null = null;
let cachedMtimeMS: number | null = null;
let cachedPath: string | null = null;

function codexGlobalStatePath(): string {
  return process.env.CODEX_GLOBAL_STATE_PATH?.trim()
    || path.join(homedir(), ".codex", ".codex-global-state.json");
}

function normalizePath(value: string | null | undefined): string {
  return path.resolve(value?.trim() || "/");
}

function readCodexWorkspaceRootLabels(): Map<string, string> {
  const filePath = codexGlobalStatePath();
  if (!existsSync(filePath)) {
    cachedLabels = new Map();
    cachedMtimeMS = null;
    cachedPath = filePath;
    return cachedLabels;
  }

  try {
    const stat = statSync(filePath);
    if (cachedLabels && cachedMtimeMS === stat.mtimeMs && cachedPath === filePath) {
      return cachedLabels;
    }

    const parsed = JSON.parse(readFileSync(filePath, "utf8")) as CodexGlobalState;
    const rawLabels = parsed["electron-workspace-root-labels"] ?? {};
    const labels = new Map<string, string>();
    for (const [root, label] of Object.entries(rawLabels)) {
      if (typeof label !== "string") {
        continue;
      }
      const normalizedLabel = label.trim();
      if (!normalizedLabel) {
        continue;
      }
      labels.set(normalizePath(root), normalizedLabel);
    }

    cachedLabels = labels;
    cachedMtimeMS = stat.mtimeMs;
    cachedPath = filePath;
    return labels;
  } catch {
    cachedLabels = new Map();
    cachedMtimeMS = null;
    cachedPath = filePath;
    return cachedLabels;
  }
}

export function codexProjectNameForPath(value: string | null | undefined): string | null {
  const normalizedPath = normalizePath(value);
  return readCodexWorkspaceRootLabels().get(normalizedPath) ?? null;
}
