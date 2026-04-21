import { execFile } from "node:child_process";
import {
  closeSync,
  existsSync,
  openSync,
  readdirSync,
  readFileSync,
  readSync,
  statSync,
} from "node:fs";
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
const MAX_LOCAL_ROLLOUT_STREAM_TEXT_LENGTH = 64_000;
const LOCAL_ROLLOUT_TAIL_READ_BYTES = 12 * 1024 * 1024;

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

const DEGRADED_CODEX_THREAD_TITLES = [
  /^helm(?:\s+ios|\s+macos)?$/i,
];

function isDegradedCodexThreadTitle(title: string, fallbackName: string | null): boolean {
  if (!fallbackName) {
    return false;
  }

  const normalizedTitle = title.trim().toLocaleLowerCase();
  const normalizedFallback = fallbackName.trim().toLocaleLowerCase();
  if (!normalizedTitle || normalizedTitle === normalizedFallback) {
    return false;
  }

  return DEGRADED_CODEX_THREAD_TITLES.some((pattern) => pattern.test(title));
}

export function preferredCodexThreadName(
  title: string | null | undefined,
  fallbackName: string | null | undefined
): string | null {
  const preferredTitle = firstLine(title);
  const preferredFallback = firstLine(fallbackName);
  if (preferredTitle && !isDegradedCodexThreadTitle(preferredTitle, preferredFallback)) {
    return preferredTitle;
  }

  return preferredFallback ?? preferredTitle ?? null;
}

export function codexThreadPreviewForDisplay(
  name: string | null | undefined,
  updatedAt: number,
  options: {
    preferRecentIdle?: boolean;
  } = {}
): string {
  const preview = firstLine(name) ?? "Codex CLI session";
  if (preview === "Codex CLI session") {
    return preview;
  }

  switch (statusForUpdatedAt(updatedAt, options)) {
  case "running":
    return "Waiting for output...";
  case "idle":
    return "No activity yet.";
  default:
    return preview;
  }
}

function threadName(row: CodexThreadRow): string | null {
  return preferredCodexThreadName(row.title, row.first_user_message);
}

function threadPreview(row: CodexThreadRow, updatedAt: number): string {
  return codexThreadPreviewForDisplay(threadName(row), updatedAt, {
    preferRecentIdle: true,
  });
}

function enrichPreview(row: CodexThreadRow, updatedAt: number): string {
  const basePreview = threadPreview(row, updatedAt);
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

function statusForUpdatedAt(
  updatedAt: number,
  options: {
    preferRecentIdle?: boolean;
  } = {}
): string {
  const ageMS = Math.max(0, Date.now() - updatedAt);
  if (options.preferRecentIdle) {
    if (ageMS < 7 * 24 * 60 * 60 * 1000) {
      return "idle";
    }
    return "unknown";
  }
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
    return parseCodexRolloutTurns(readCodexRolloutTailText(rolloutPath), threadId);
  } catch (error) {
    console.warn(`[bridge] failed to read local Codex rollout ${rolloutPath}: ${errorMessage(error)}`);
    return [];
  }
}

export function readCodexRolloutTailText(
  rolloutPath: string,
  maxBytes: number = LOCAL_ROLLOUT_TAIL_READ_BYTES
): string {
  const size = statSync(rolloutPath).size;
  if (size <= maxBytes) {
    return readFileSync(rolloutPath, "utf8");
  }

  const byteCount = Math.min(size, maxBytes);
  const start = size - byteCount;
  const buffer = Buffer.allocUnsafe(byteCount);
  const fd = openSync(rolloutPath, "r");
  try {
    readSync(fd, buffer, 0, byteCount, start);
  } finally {
    closeSync(fd);
  }

  const text = buffer.toString("utf8");
  const firstNewline = text.search(/\r?\n/);
  if (firstNewline === -1) {
    return text;
  }

  const newlineWidth = text[firstNewline] === "\r" && text[firstNewline + 1] === "\n"
    ? 2
    : 1;
  return text.slice(firstNewline + newlineWidth);
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

export function parseCodexRolloutTurns(content: string, threadId: string): JSONValue[] {
  const turns = new Map<string, { id: string; status: string; items: JSONValue[]; lastTouchedIndex: number }>();
  let currentTurnId = `local-rollout-${threadId}`;

  const getTurn = (turnId: string, lastTouchedIndex: number) => {
    let turn = turns.get(turnId);
    if (!turn) {
      turn = { id: turnId, status: "completed", items: [], lastTouchedIndex };
      turns.set(turnId, turn);
    } else {
      turn.lastTouchedIndex = Math.max(turn.lastTouchedIndex, lastTouchedIndex);
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
      getTurn(currentTurnId, index).status = "running";
      continue;
    }

    const turnId = stringValue(payload.turn_id) ?? currentTurnId;
    if (record.type === "event_msg" && payloadType === "task_complete") {
      getTurn(turnId, index).status = "completed";
      currentTurnId = `local-rollout-${threadId}`;
      continue;
    }

    const item = localRolloutItem(record.type, payloadType, payload, index + 1);
    if (item) {
      getTurn(turnId, index).items.push(item);
    }
  }

  return Array.from(turns.values())
    .filter((turn) => turn.items.length > 0)
    .sort((left, right) => right.lastTouchedIndex - left.lastTouchedIndex)
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
      const text = boundedHeadText(stringValue(payload.message));
      return text
        ? {
            id: `local-user-${index}`,
            type: "userMessage",
            content: { text },
          }
        : null;
    }
    case "agent_message": {
      const text = boundedTailText(stringValue(payload.message));
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
        aggregatedOutput: boundedTailText(stringValue(payload.aggregated_output)),
        stdout: boundedTailText(stringValue(payload.stdout)),
        stderr: boundedTailText(stringValue(payload.stderr)),
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
    case "view_image_tool_call": {
      const imagePath = boundedHeadText(stringValue(payload.path));
      return {
        id: `local-view-image-${index}`,
        type: "dynamicToolCall",
        tool: "Viewed Image",
        contentItems: imagePath,
        status: "completed",
      };
    }
    case "mcp_tool_call_end": {
      return {
        id: `local-mcp-tool-${index}`,
        type: "dynamicToolCall",
        tool: localMCPToolTitle(payload),
        contentItems: boundedHeadText(readableToolResult(payload.result) ?? readableToolResult(payload.error)),
        status: payload.error ? "failed" : "completed",
      };
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
      unified_diff: boundedHeadText(stringValue(changeObject.unified_diff)),
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

function localMCPToolTitle(payload: { [key: string]: JSONValue }): string {
  const invocation = objectValue(payload.invocation);
  const server = stringValue(invocation?.server) ?? "MCP";
  const tool = stringValue(invocation?.tool) ?? "tool";
  const argumentsText = compactJSON(invocation?.arguments) ?? "{}";
  return `Called ${server}.${tool}(${argumentsText})`;
}

function readableToolResult(value: JSONValue | undefined): string | null {
  if (typeof value === "string") {
    return value;
  }

  if (Array.isArray(value)) {
    return value
      .map((entry) => readableToolResult(entry))
      .filter((entry): entry is string => Boolean(entry))
      .join("\n")
      .trim() || null;
  }

  const object = objectValue(value);
  if (!object) {
    return null;
  }

  for (const key of ["text", "message", "stdout", "stderr", "error"]) {
    const text = stringValue(object[key]);
    if (text) {
      return text;
    }
  }

  for (const key of ["Ok", "Err", "result", "output", "content"]) {
    const text = readableToolResult(object[key]);
    if (text) {
      return text;
    }
  }

  return compactJSON(value);
}

function compactJSON(value: JSONValue | undefined): string | null {
  if (value === undefined) {
    return null;
  }

  try {
    return JSON.stringify(value);
  } catch {
    return null;
  }
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

function boundedHeadText(value: string | null, maxLength = MAX_LOCAL_ROLLOUT_TEXT_LENGTH): string | null {
  if (!value) {
    return null;
  }

  if (value.length <= maxLength) {
    return value;
  }

  return value.slice(0, maxLength).trimEnd();
}

function boundedTailText(value: string | null, maxLength = MAX_LOCAL_ROLLOUT_STREAM_TEXT_LENGTH): string | null {
  if (!value) {
    return null;
  }

  if (value.length <= maxLength) {
    return value;
  }

  return value.slice(-maxLength).trimStart();
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
    status: statusForUpdatedAt(updatedAt, {
      preferRecentIdle: true,
    }),
    updatedAt,
    sourceKind: row.source ?? "cli",
    launchSource: exactLaunch ? HELM_RUNTIME_LAUNCH_SOURCE : null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
}
