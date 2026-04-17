import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export type CodexThreadReplacementRecord = {
  runtime: string;
  oldThreadId: string;
  newThreadId: string;
  replacedAt: number;
};

function registryPath(): string {
  return path.join(homedir(), ".config", "helm", "thread-replacements");
}

function ensureRegistryPath(): string {
  const target = registryPath();
  if (!existsSync(target)) {
    mkdirSync(target, { recursive: true });
  }
  return target;
}

function parseRecord(filePath: string): CodexThreadReplacementRecord | null {
  try {
    const raw = readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw) as Partial<CodexThreadReplacementRecord>;
    if (
      typeof parsed.runtime === "string" &&
      typeof parsed.oldThreadId === "string" &&
      typeof parsed.newThreadId === "string" &&
      typeof parsed.replacedAt === "number"
    ) {
      return {
        runtime: parsed.runtime,
        oldThreadId: parsed.oldThreadId,
        newThreadId: parsed.newThreadId,
        replacedAt: parsed.replacedAt,
      };
    }
  } catch {
    // Ignore malformed records.
  }

  return null;
}

function recordPath(runtime: string, oldThreadId: string): string {
  return path.join(ensureRegistryPath(), `${runtime}-${oldThreadId}.json`);
}

export function listCodexThreadReplacements(runtime?: string): CodexThreadReplacementRecord[] {
  const folder = ensureRegistryPath();
  const records: CodexThreadReplacementRecord[] = [];

  for (const entry of readdirSync(folder)) {
    if (!entry.endsWith(".json")) {
      continue;
    }

    const filePath = path.join(folder, entry);
    const record = parseRecord(filePath);
    if (!record) {
      rmSync(filePath, { force: true });
      continue;
    }

    if (runtime && record.runtime !== runtime) {
      continue;
    }

    records.push(record);
  }

  return records.sort((lhs, rhs) => rhs.replacedAt - lhs.replacedAt);
}

export function readCodexThreadReplacement(
  runtime: string,
  oldThreadId: string
): CodexThreadReplacementRecord | null {
  return parseRecord(recordPath(runtime, oldThreadId));
}

export function resolveCodexThreadReplacement(
  runtime: string,
  threadId: string
): CodexThreadReplacementRecord | null {
  let currentThreadId = threadId;
  let resolved: CodexThreadReplacementRecord | null = null;
  const seen = new Set<string>();

  while (!seen.has(currentThreadId)) {
    seen.add(currentThreadId);
    const replacement = readCodexThreadReplacement(runtime, currentThreadId);
    if (!replacement) {
      break;
    }
    resolved = replacement;
    currentThreadId = replacement.newThreadId;
  }

  return resolved;
}

export function canonicalCodexThreadId(runtime: string, threadId: string): string {
  return resolveCodexThreadReplacement(runtime, threadId)?.newThreadId ?? threadId;
}

export function deleteCodexThreadReplacement(runtime: string, oldThreadId: string): void {
  rmSync(recordPath(runtime, oldThreadId), { force: true });
}

export function recordCodexThreadReplacement(
  runtime: string,
  oldThreadId: string,
  newThreadId: string
): CodexThreadReplacementRecord {
  const record: CodexThreadReplacementRecord = {
    runtime,
    oldThreadId,
    newThreadId,
    replacedAt: Date.now(),
  };

  writeFileSync(recordPath(runtime, oldThreadId), JSON.stringify(record), "utf8");
  return record;
}
