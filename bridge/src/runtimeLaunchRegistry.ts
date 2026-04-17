import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

import { canonicalCodexThreadId } from "./codexThreadReplacementRegistry.js";

export type RuntimeLaunchRecord = {
  runtime: string;
  pid: number;
  runtimePid: number | null;
  cwd: string;
  launchedAt: number;
  wrapper: string | null;
  ipcSocket: string | null;
  outputTailPath: string | null;
  threadId: string | null;
};

export type RuntimeOutputTail = {
  updatedAt: number;
  text: string;
};

export function canonicalRuntimeThreadId(
  runtime: string,
  threadId: string | null | undefined
): string | null {
  if (!threadId) {
    return null;
  }

  if (runtime === "codex") {
    return canonicalCodexThreadId("codex", threadId);
  }

  return threadId;
}

function registryPath(): string {
  return path.join(homedir(), ".config", "helm", "runtime-launches");
}

function isProcessAlive(pid: number | undefined): boolean {
  if (!pid || pid <= 0) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function ensureRegistryPath(): string {
  const target = registryPath();
  if (!existsSync(target)) {
    mkdirSync(target, { recursive: true });
  }
  return target;
}

function parseRecord(filePath: string): RuntimeLaunchRecord | null {
  try {
    const raw = readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw) as Partial<RuntimeLaunchRecord>;
    if (
      typeof parsed.runtime === "string" &&
      typeof parsed.pid === "number" &&
      typeof parsed.cwd === "string" &&
      typeof parsed.launchedAt === "number"
    ) {
      return {
        runtime: parsed.runtime,
        pid: parsed.pid,
        runtimePid: typeof parsed.runtimePid === "number" ? parsed.runtimePid : null,
        cwd: parsed.cwd,
        launchedAt: parsed.launchedAt,
        wrapper: typeof parsed.wrapper === "string" ? parsed.wrapper : null,
        ipcSocket: typeof parsed.ipcSocket === "string" ? parsed.ipcSocket : null,
        outputTailPath: typeof parsed.outputTailPath === "string" ? parsed.outputTailPath : null,
        threadId: typeof parsed.threadId === "string" ? parsed.threadId : null,
      };
    }
  } catch {
    // Ignore malformed files.
  }

  return null;
}

export function listRuntimeLaunches(runtime?: string): RuntimeLaunchRecord[] {
  const folder = ensureRegistryPath();
  const records: RuntimeLaunchRecord[] = [];

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

    if (!isProcessAlive(record.pid)) {
      rmSync(filePath, { force: true });
      continue;
    }

    if (runtime && record.runtime !== runtime) {
      continue;
    }

    records.push(record);
  }

  return records.sort((lhs, rhs) => rhs.launchedAt - lhs.launchedAt);
}

export function isRuntimeRelayAvailable(
  launch: RuntimeLaunchRecord | null | undefined
): launch is RuntimeLaunchRecord {
  return Boolean(launch?.ipcSocket && existsSync(launch.ipcSocket));
}

export function updateRuntimeLaunchThreadId(
  runtime: string,
  pid: number,
  threadId: string
): RuntimeLaunchRecord | null {
  const folder = ensureRegistryPath();

  for (const entry of readdirSync(folder)) {
    if (!entry.endsWith(".json")) {
      continue;
    }

    const filePath = path.join(folder, entry);
    const record = parseRecord(filePath);
    if (!record || record.runtime !== runtime || record.pid !== pid) {
      continue;
    }
    if (!isProcessAlive(record.pid)) {
      rmSync(filePath, { force: true });
      return null;
    }

    const next = { ...record, threadId };
    writeFileSync(filePath, JSON.stringify(next), "utf8");
    return next;
  }

  return null;
}

export function findMatchingLaunchByPID(runtime: string, pid: number | undefined): RuntimeLaunchRecord | null {
  if (!pid || pid <= 0) {
    return null;
  }

  return listRuntimeLaunches(runtime).find((record) => record.pid === pid || record.runtimePid === pid) ?? null;
}

export function findMatchingLaunchByThreadID(
  runtime: string,
  threadId: string | undefined | null
): RuntimeLaunchRecord | null {
  const requestedThreadId = canonicalRuntimeThreadId(runtime, threadId);
  if (!requestedThreadId) {
    return null;
  }

  const matches = listRuntimeLaunches(runtime).filter((record) => {
    return canonicalRuntimeThreadId(runtime, record.threadId) === requestedThreadId;
  });

  return matches.find(isRuntimeRelayAvailable) ?? matches[0] ?? null;
}

export function findMatchingLaunchByCWD(runtime: string, cwd: string, updatedAt?: number): RuntimeLaunchRecord | null {
  const matches = listRuntimeLaunches(runtime).filter((record) => record.cwd === cwd);
  if (matches.length === 0) {
    return null;
  }

  const availableMatches = matches.filter(isRuntimeRelayAvailable);
  const candidates = availableMatches.length > 0 ? availableMatches : matches;

  if (!updatedAt || !Number.isFinite(updatedAt)) {
    return candidates[0] ?? null;
  }

  return candidates.reduce<RuntimeLaunchRecord | null>((best, candidate) => {
    if (!best) {
      return candidate;
    }

    const bestDistance = Math.abs(best.launchedAt - updatedAt);
    const candidateDistance = Math.abs(candidate.launchedAt - updatedAt);
    return candidateDistance < bestDistance ? candidate : best;
  }, null);
}

export function readRuntimeOutputTail(launch: RuntimeLaunchRecord): RuntimeOutputTail | null {
  const filePath = launch.outputTailPath;
  if (!filePath || !existsSync(filePath)) {
    return null;
  }

  try {
    const raw = readFileSync(filePath, "utf8");
    const parsed = JSON.parse(raw) as Partial<RuntimeOutputTail>;
    if (typeof parsed.updatedAt !== "number" || typeof parsed.text !== "string") {
      return null;
    }

    const text = parsed.text.trim();
    if (!text) {
      return null;
    }

    return {
      updatedAt: parsed.updatedAt,
      text,
    };
  } catch {
    return null;
  }
}
