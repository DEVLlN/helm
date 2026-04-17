import { execFile } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { HELM_RUNTIME_LAUNCH_SOURCE } from "./helmManagedLaunch.js";
import { listCodexThreadReplacements } from "./codexThreadReplacementRegistry.js";
import { findMatchingLaunchByCWD, findMatchingLaunchByThreadID } from "./runtimeLaunchRegistry.js";
import type { JSONValue, ThreadSummary } from "./types.js";

const execFileAsync = promisify(execFile);
const DEFAULT_LIMIT = 50;
const MAX_LOCAL_ROLLOUT_TEXT_LENGTH = 20_000;

type CodexThreadRow = {
  id?: string;
  updated_at?: number;
  cwd?: string;
  title?: string | null;
  first_user_message?: string | null;
  source?: string | null;
  archived?: number;
  rollout_path?: string | null;
};

type CodexNamedThreadCandidate = {
  thread: ThreadSummary;
  archived: boolean;
  computedName: string;
};

export type ResolvedCodexThreadName =
  | {
      status: "resolved";
      matchKind: "exact" | "caseInsensitive";
      thread: ThreadSummary;
    }
  | {
      status: "ambiguous";
      matchKind: "exact" | "caseInsensitive";
      matches: ThreadSummary[];
    }
  | {
      status: "notFound";
    };

function codexStatePath(): string {
  return path.join(homedir(), ".codex", "state_5.sqlite");
}

function truncate(text: string, maxLength: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function firstLine(value: string | null | undefined): string | null {
  if (!value) {
    return null;
  }

  const line = value
    .split(/\r?\n/)
    .map((entry) => entry.trim())
    .find((entry) => entry.length > 0);

  return line ? truncate(line, 140) : null;
}

function threadName(row: CodexThreadRow): string | null {
  return firstLine(row.title) ?? firstLine(row.first_user_message) ?? null;
}

function threadPreview(row: CodexThreadRow): string {
  return threadName(row) ?? "Codex CLI session";
}

function enrichPreview(row: CodexThreadRow, updatedAt: number): string {
  const basePreview = threadPreview(row);
  if (!row.cwd) {
    return basePreview;
  }

  const launch =
    findMatchingLaunchByThreadID("codex", row.id) ??
    findMatchingLaunchByCWD("codex", row.cwd, updatedAt);
  if (!launch) {
    return basePreview;
  }

  return basePreview == "Codex CLI session"
    ? "helm-managed Codex CLI session"
    : `${basePreview} • via helm`
}

function normalizeUpdatedAt(value: number | undefined): number {
  if (!value || !Number.isFinite(value)) {
    return Date.now();
  }

  return value > 1_000_000_000_000 ? value : value * 1000;
}

function statusForUpdatedAt(updatedAt: number): string {
  const ageMS = Math.max(0, Date.now() - updatedAt);
  if (ageMS < 15 * 60 * 1000) {
    return "running";
  }
  if (ageMS < 7 * 24 * 60 * 60 * 1000) {
    return "idle";
  }
  return "unknown";
}

export async function discoverCodexThreads(limit = DEFAULT_LIMIT): Promise<ThreadSummary[]> {
  const rows = await queryCodexThreadRows(`
    select
      id,
      updated_at,
      cwd,
      nullif(title, '') as title,
      nullif(first_user_message, '') as first_user_message,
      source
    from threads
    where archived = 0
      and source in ('cli', 'appServer', 'vscode')
    order by updated_at desc
    limit ${Math.max(1, Math.min(limit, 200))};
  `);

  return rowsToSummaries(rows);
}

export async function discoverCodexThread(threadId: string): Promise<ThreadSummary | null> {
  const row = await queryCodexThreadRow(threadId, `
    select
      id,
      updated_at,
      cwd,
      nullif(title, '') as title,
      nullif(first_user_message, '') as first_user_message,
      source,
      rollout_path
    from threads
    where id = ?
      and source in ('cli', 'appServer', 'vscode')
    limit 1;
  `);

  return row ? rowToSummary(row) : null;
}

export async function readCodexThreadLocalTurns(threadId: string): Promise<JSONValue[]> {
  const row = await queryCodexThreadRow(threadId, `
    select
      id,
      rollout_path
    from threads
    where id = ?
      and source in ('cli', 'appServer', 'vscode')
    limit 1;
  `);
  const rolloutPath = resolveCodexRolloutPath(threadId, row?.rollout_path);
  if (!rolloutPath) {
    return [];
  }

  try {
    return parseCodexRolloutTurns(readFileSync(rolloutPath, "utf8"), threadId);
  } catch (error) {
    console.warn(`[bridge] failed to read local Codex rollout ${rolloutPath}: ${errorMessage(error)}`);
    return [];
  }
}

export async function resolveCodexThreadRolloutPath(threadId: string): Promise<string | null> {
  const row = await queryCodexThreadRow(threadId, `
    select
      id,
      rollout_path
    from threads
    where id = ?
      and source in ('cli', 'appServer', 'vscode')
    limit 1;
  `);

  return resolveCodexRolloutPath(threadId, row?.rollout_path);
}

export async function resolveCodexThreadByName(name: string): Promise<ResolvedCodexThreadName> {
  const trimmedName = name.trim();
  if (!trimmedName) {
    return { status: "notFound" };
  }

  const candidates = await loadNamedThreadCandidates();
  const exactMatches = selectPreferredNameMatches(
    candidates.filter((candidate) => candidate.computedName === trimmedName)
  );
  if (exactMatches.length === 1) {
    return {
      status: "resolved",
      matchKind: "exact",
      thread: exactMatches[0]!.thread,
    };
  }
  if (exactMatches.length > 1) {
    return {
      status: "ambiguous",
      matchKind: "exact",
      matches: exactMatches.map((candidate) => candidate.thread),
    };
  }

  const foldedName = trimmedName.toLocaleLowerCase();
  const foldedMatches = selectPreferredNameMatches(
    candidates.filter((candidate) => candidate.computedName.toLocaleLowerCase() === foldedName)
  );
  if (foldedMatches.length === 1) {
    return {
      status: "resolved",
      matchKind: "caseInsensitive",
      thread: foldedMatches[0]!.thread,
    };
  }
  if (foldedMatches.length > 1) {
    return {
      status: "ambiguous",
      matchKind: "caseInsensitive",
      matches: foldedMatches.map((candidate) => candidate.thread),
    };
  }

  return { status: "notFound" };
}

async function queryCodexThreadRows(query: string): Promise<CodexThreadRow[]> {
  const sqlitePath = codexStatePath();
  if (!existsSync(sqlitePath)) {
    return [];
  }

  try {
    const { stdout } = await execFileAsync("sqlite3", ["-json", sqlitePath, query], {
      maxBuffer: 8 * 1024 * 1024,
    });
    return JSON.parse(stdout || "[]") as CodexThreadRow[];
  } catch {
    return [];
  }
}

async function queryCodexThreadRow(threadId: string, query: string): Promise<CodexThreadRow | null> {
  const sanitizedThreadId = threadId.replace(/'/g, "''");
  const rows = await queryCodexThreadRows(query.replace("?", `'${sanitizedThreadId}'`));
  return rows[0] ?? null;
}

function resolveCodexRolloutPath(
  threadId: string,
  rolloutPath: string | null | undefined
): string | null {
  if (rolloutPath && existsSync(rolloutPath)) {
    return rolloutPath;
  }

  const archivedDirectory = path.join(homedir(), ".codex", "archived_sessions");
  if (!existsSync(archivedDirectory)) {
    return null;
  }

  if (rolloutPath) {
    const archivedPath = path.join(archivedDirectory, path.basename(rolloutPath));
    if (existsSync(archivedPath)) {
      return archivedPath;
    }
  }

  try {
    const match = readdirSync(archivedDirectory)
      .filter((entry) => entry.includes(threadId) && entry.endsWith(".jsonl"))
      .sort()
      .at(-1);
    return match ? path.join(archivedDirectory, match) : null;
  } catch {
    return null;
  }
}

function parseCodexRolloutTurns(content: string, threadId: string): JSONValue[] {
  const turns = new Map<string, { id: string; status: string; items: JSONValue[] }>();
  let currentTurnId = `local-rollout-${threadId}`;

  const getTurn = (turnId: string) => {
    let turn = turns.get(turnId);
    if (!turn) {
      turn = { id: turnId, status: "completed", items: [] };
      turns.set(turnId, turn);
    }
    return turn;
  };

  for (const [index, line] of content.split(/\r?\n/).entries()) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    const record = parseJSONObject(trimmed);
    const payload = objectValue(record?.payload);
    const payloadType = stringValue(payload?.type);
    if (!record || !payload || !payloadType) {
      continue;
    }

    if (record.type === "event_msg" && payloadType === "task_started") {
      currentTurnId = stringValue(payload.turn_id) ?? currentTurnId;
      getTurn(currentTurnId).status = "running";
      continue;
    }

    const turnId = stringValue(payload.turn_id) ?? currentTurnId;
    if (record.type === "event_msg" && payloadType === "task_complete") {
      getTurn(turnId).status = "completed";
      currentTurnId = `local-rollout-${threadId}`;
      continue;
    }

    const item = localRolloutItem(record.type, payloadType, payload, index + 1);
    if (item) {
      getTurn(turnId).items.push(item);
    }
  }

  return Array.from(turns.values())
    .filter((turn) => turn.items.length > 0)
    .map((turn) => ({
      id: turn.id,
      status: turn.status,
      items: turn.items,
    }));
}

function localRolloutItem(
  recordType: JSONValue | undefined,
  payloadType: string,
  payload: { [key: string]: JSONValue },
  index: number
): JSONValue | null {
  if (recordType !== "event_msg") {
    return null;
  }

  switch (payloadType) {
    case "user_message": {
      const text = boundedText(stringValue(payload.message));
      return text
        ? {
            id: `local-user-${index}`,
            type: "userMessage",
            content: { text },
          }
        : null;
    }
    case "agent_message": {
      const text = boundedText(stringValue(payload.message));
      return text
        ? {
            id: `local-agent-${index}`,
            type: "agentMessage",
            text,
            phase: stringValue(payload.phase) ?? null,
          }
        : null;
    }
    case "exec_command_end": {
      const command = commandText(payload.command);
      return {
        id: `local-command-${index}`,
        type: "commandExecution",
        command: command ?? "Command execution",
        cwd: stringValue(payload.cwd) ?? null,
        exitCode: numberValue(payload.exit_code),
        status: stringValue(payload.status) ?? null,
        aggregatedOutput: boundedText(stringValue(payload.aggregated_output)),
        stdout: boundedText(stringValue(payload.stdout)),
        stderr: boundedText(stringValue(payload.stderr)),
      };
    }
    case "patch_apply_end": {
      const changes = rolloutFileChanges(payload.changes);
      return changes.length > 0
        ? {
            id: `local-file-change-${index}`,
            type: "fileChange",
            status: stringValue(payload.status) ?? null,
            changes,
          }
        : null;
    }
    default:
      return null;
  }
}

function rolloutFileChanges(value: JSONValue | undefined): JSONValue[] {
  const changes = objectValue(value);
  if (!changes) {
    return [];
  }

  const result: JSONValue[] = [];
  for (const [filePath, change] of Object.entries(changes)) {
    const changeObject = objectValue(change);
    if (!changeObject) {
      continue;
    }

    result.push({
      path: filePath,
      type: stringValue(changeObject.type) ?? "update",
      unified_diff: boundedText(stringValue(changeObject.unified_diff)),
    });
  }

  return result;
}

function parseJSONObject(value: string): { [key: string]: JSONValue } | null {
  try {
    return objectValue(JSON.parse(value) as JSONValue);
  } catch {
    return null;
  }
}

function objectValue(value: JSONValue | undefined): { [key: string]: JSONValue } | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value : null;
}

function stringValue(value: JSONValue | undefined): string | null {
  return typeof value === "string" ? value : null;
}

function numberValue(value: JSONValue | undefined): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function commandText(value: JSONValue | undefined): string | null {
  if (typeof value === "string") {
    return value;
  }

  if (Array.isArray(value)) {
    return value
      .filter((entry): entry is string => typeof entry === "string")
      .join(" ")
      .trim() || null;
  }

  return null;
}

function boundedText(value: string | null): string | null {
  if (!value) {
    return null;
  }

  if (value.length <= MAX_LOCAL_ROLLOUT_TEXT_LENGTH) {
    return value;
  }

  return `${value.slice(0, MAX_LOCAL_ROLLOUT_TEXT_LENGTH).trimEnd()}\n… truncated from local Codex rollout …`;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function loadNamedThreadCandidates(): Promise<CodexNamedThreadCandidate[]> {
  const replacedThreadIDs = new Set(
    listCodexThreadReplacements("codex").map((record) => record.oldThreadId)
  );
  const rows = await queryCodexThreadRows(`
    select
      id,
      updated_at,
      cwd,
      nullif(title, '') as title,
      nullif(first_user_message, '') as first_user_message,
      source,
      archived
    from threads
    where source in ('cli', 'appServer', 'vscode')
    order by archived asc, updated_at desc;
  `);

  return rows
    .filter((row) => typeof row.id === "string" && row.id.length > 0 && !replacedThreadIDs.has(row.id))
    .map((row) => {
      const thread = rowToSummary(row);
      const computedName = thread?.name?.trim() ?? "";
      if (!thread || !computedName) {
        return null;
      }

      return {
        thread,
        archived: row.archived === 1,
        computedName,
      };
    })
    .filter((candidate): candidate is CodexNamedThreadCandidate => candidate !== null);
}

function selectPreferredNameMatches(matches: CodexNamedThreadCandidate[]): CodexNamedThreadCandidate[] {
  if (matches.length === 0) {
    return [];
  }

  const activeMatches = matches.filter((candidate) => !candidate.archived);
  return activeMatches.length > 0 ? activeMatches : matches;
}

function rowsToSummaries(rows: CodexThreadRow[]): ThreadSummary[] {
  return rows
    .map((row) => rowToSummary(row))
    .filter((thread): thread is ThreadSummary => thread !== null);
}

function rowToSummary(row: CodexThreadRow): ThreadSummary | null {
  if (typeof row.id !== "string" || row.id.length === 0 || typeof row.cwd !== "string") {
    return null;
  }

  const updatedAt = normalizeUpdatedAt(row.updated_at);
  const exactLaunch = findMatchingLaunchByThreadID("codex", row.id);
  return {
    id: row.id,
    name: threadName(row),
    preview: enrichPreview(row, updatedAt),
    cwd: row.cwd,
    status: statusForUpdatedAt(updatedAt),
    updatedAt,
    sourceKind: row.source ?? "cli",
    launchSource: exactLaunch ? HELM_RUNTIME_LAUNCH_SOURCE : null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
}
