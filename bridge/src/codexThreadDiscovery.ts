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
import type { JSONValue, ThreadImageAttachment, ThreadSummary } from "./types.js";

const execFileAsync = promisify(execFile);
const DEFAULT_LIMIT = 50;
const MAX_LOCAL_ROLLOUT_TEXT_LENGTH = 20_000;
const MAX_LOCAL_ROLLOUT_STREAM_TEXT_LENGTH = 64_000;
const LOCAL_ROLLOUT_TAIL_READ_BYTES = 12 * 1024 * 1024;
const LOCAL_IMAGE_PATH_RE =
  /(?:^|[\s("'`])((?:\/Users\/|\/private\/var\/|\/var\/folders\/|\/tmp\/)[^\s"'`)<]+?\.(?:png|jpe?g|webp|gif|heic|heif))(?:$|[\s"')>`])/giu;

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

export type CodexThreadLocalSnapshot = {
  turns: JSONValue[];
  updatedAt: number | null;
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
  return (await readCodexThreadLocalSnapshot(threadId)).turns;
}

export async function readCodexThreadLocalSnapshot(threadId: string): Promise<CodexThreadLocalSnapshot> {
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
    return { turns: [], updatedAt: null };
  }

  try {
    const content = readCodexRolloutTailText(rolloutPath);
    return {
      turns: parseCodexRolloutTurns(content, threadId),
      updatedAt: parseCodexRolloutUpdatedAt(content),
    };
  } catch (error) {
    console.warn(`[bridge] failed to read local Codex rollout ${rolloutPath}: ${errorMessage(error)}`);
    return { turns: [], updatedAt: null };
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
  let pendingUnscopedFinalItems: JSONValue[] = [];

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

  const appendPendingFinalItems = (turnId: string, lastTouchedIndex: number) => {
    if (pendingUnscopedFinalItems.length === 0) {
      return;
    }

    const turn = getTurn(turnId, lastTouchedIndex);
    for (const item of pendingUnscopedFinalItems) {
      appendLocalRolloutItem(turn, item);
    }
    pendingUnscopedFinalItems = [];
  };

  const lines = content.split(/\r?\n/);
  for (const [index, line] of lines.entries()) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    const record = parseJSONObject(trimmed);
    const payload = objectValue(record?.payload);
    if (record?.type === "turn_context") {
      const contextTurnId = stringValue(payload?.turn_id);
      if (contextTurnId) {
        currentTurnId = contextTurnId;
        getTurn(currentTurnId, index).status = "running";
      }
      continue;
    }

    const payloadType = stringValue(payload?.type);
    if (!record || !payload || !payloadType) {
      continue;
    }

    if (record.type === "event_msg" && payloadType === "task_started") {
      appendPendingFinalItems(currentTurnId, index);
      currentTurnId = stringValue(payload.turn_id) ?? currentTurnId;
      getTurn(currentTurnId, index).status = "running";
      continue;
    }

    const turnId = stringValue(payload.turn_id) ?? currentTurnId;
    if (record.type === "event_msg" && payloadType === "task_complete") {
      const turn = getTurn(turnId, index);
      appendPendingFinalItems(turnId, index);
      const completeItem = taskCompleteRolloutItem(payload, index + 1);
      if (completeItem) {
        appendLocalRolloutItem(turn, completeItem);
      }
      turn.status = "completed";
      currentTurnId = `local-rollout-${threadId}`;
      continue;
    }

    const item = localRolloutItem(record.type, payloadType, payload, index + 1);
    if (item) {
      if (isUnscopedFinalAnswerMessage(record.type, payloadType, payload)) {
        pendingUnscopedFinalItems.push(item);
        continue;
      }

      appendLocalRolloutItem(getTurn(turnId, index), item);
    }
  }

  appendPendingFinalItems(currentTurnId, lines.length);

  return Array.from(turns.values())
    .filter((turn) => turn.items.length > 0)
    .sort((left, right) => right.lastTouchedIndex - left.lastTouchedIndex)
    .map((turn) => ({
      id: turn.id,
      status: turn.status,
      items: turn.items,
    }));
}

export function parseCodexRolloutUpdatedAt(content: string): number | null {
  let updatedAt: number | null = null;
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    const record = parseJSONObject(trimmed);
    const timestamp = stringValue(record?.timestamp);
    if (!timestamp) {
      continue;
    }

    const time = Date.parse(timestamp);
    if (!Number.isFinite(time)) {
      continue;
    }

    updatedAt = Math.max(updatedAt ?? 0, time);
  }

  return updatedAt;
}

function taskCompleteRolloutItem(
  payload: { [key: string]: JSONValue },
  index: number
): JSONValue | null {
  const text = boundedTailText(stripMemoryCitationBlock(stringValue(payload.last_agent_message) ?? ""));
  return text
    ? {
        id: `local-agent-complete-${index}`,
        type: "agentMessage",
        text,
        phase: "final_answer",
      }
    : null;
}

function isUnscopedFinalAnswerMessage(
  recordType: JSONValue | undefined,
  payloadType: string,
  payload: { [key: string]: JSONValue }
): boolean {
  if (stringValue(payload.turn_id)) {
    return false;
  }
  if (stringValue(payload.phase) !== "final_answer") {
    return false;
  }

  return (
    (recordType === "event_msg" && payloadType === "agent_message")
    || (recordType === "response_item" && payloadType === "message")
  );
}

function localRolloutItem(
  recordType: JSONValue | undefined,
  payloadType: string,
  payload: { [key: string]: JSONValue },
  index: number
): JSONValue | null {
  if (recordType === "response_item") {
    if (payloadType === "message") {
      return responseMessageRolloutItem(payload, index);
    }
    if (payloadType === "function_call" && stringValue(payload.name) === "update_plan") {
      return updatePlanRolloutItem(payload, index);
    }
  }

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
      const imageAttachments = imagePath
        ? imageAttachmentsFromPaths([imagePath], `local-view-image-${index}`, "view_image")
        : [];
      return {
        id: `local-view-image-${index}`,
        type: "dynamicToolCall",
        tool: "Viewed Image",
        contentItems: imagePath,
        status: "completed",
        ...(imageAttachments.length > 0 ? { imageAttachments } : {}),
      };
    }
    case "image_generation_end": {
      const imagePath = boundedHeadText(
        stringValue(payload.saved_path) ??
        stringValue(payload.path) ??
        stringValue(payload.output_path)
      );
      if (!imagePath) {
        return null;
      }

      const imageAttachments = imageAttachmentsFromPaths([imagePath], `local-generated-image-${index}`, "image_generation");
      return {
        id: `local-generated-image-${index}`,
        type: "dynamicToolCall",
        tool: "Generated Image",
        contentItems: imagePath,
        status: "completed",
        metadataSummary: boundedHeadText(stringValue(payload.revised_prompt), 280),
        ...(imageAttachments.length > 0 ? { imageAttachments } : {}),
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

function appendLocalRolloutItem(
  turn: { items: JSONValue[] },
  item: JSONValue
): void {
  const identity = localRolloutItemIdentity(item);
  if (identity && turn.items.some((existing) => localRolloutItemIdentity(existing) === identity)) {
    return;
  }

  turn.items.push(item);
}

function localRolloutItemIdentity(item: JSONValue): string | null {
  const itemObject = objectValue(item);
  const type = stringValue(itemObject?.type);
  if (!itemObject || !type) {
    return null;
  }

  switch (type) {
    case "userMessage": {
      const content = objectValue(itemObject.content);
      const text = comparableRolloutText(stringValue(content?.text));
      return text ? `user:${text}` : null;
    }
    case "agentMessage": {
      const text = comparableRolloutText(stringValue(itemObject.text));
      return text ? `agent:${text}` : null;
    }
    case "dynamicToolCall": {
      const tool = comparableRolloutText(stringValue(itemObject.tool));
      const contentItems = comparableRolloutText(stringValue(itemObject.contentItems));
      const imageAttachmentText = Array.isArray(itemObject.imageAttachments)
        ? itemObject.imageAttachments
            .map((entry) => stringValue(objectValue(entry)?.path))
            .filter((entry): entry is string => Boolean(entry))
            .join(",")
        : "";
      return tool || contentItems || imageAttachmentText
        ? `tool:${tool ?? ""}:${contentItems ?? ""}:${imageAttachmentText}`
        : null;
    }
    case "plan": {
      const text = comparableRolloutText(stringValue(itemObject.text));
      return text ? `plan:${text}` : null;
    }
    case "commandExecution": {
      return [
        "command",
        stringValue(itemObject.command) ?? "",
        numberValue(itemObject.exitCode)?.toString() ?? "",
        stringValue(itemObject.aggregatedOutput) ?? "",
      ].join(":");
    }
    default:
      return null;
  }
}

function updatePlanRolloutItem(
  payload: { [key: string]: JSONValue },
  index: number
): JSONValue | null {
  const argumentsText = stringValue(payload.arguments);
  if (!argumentsText) {
    return null;
  }

  const parsed = parseJSONObject(argumentsText);
  const plan = Array.isArray(parsed?.plan) ? parsed.plan : [];
  const lines = plan
    .map(updatePlanTaskLine)
    .filter((line): line is string => line !== null);
  if (lines.length === 0) {
    return null;
  }

  const completedCount = lines.filter((line) => line.startsWith("\u{2713} ")).length;
  const title = `${completedCount} out of ${lines.length} task${lines.length === 1 ? "" : "s"} completed`;
  const explanation = stringValue(parsed?.explanation);
  const text = [title, ...lines].join("\n");

  return {
    id: `local-plan-${index}`,
    type: "plan",
    title,
    text,
    metadataSummary: explanation ? boundedHeadText(explanation) : null,
  };
}

function updatePlanTaskLine(value: JSONValue): string | null {
  const task = objectValue(value);
  if (!task) {
    return null;
  }

  const step = stringValue(task.step)?.trim();
  if (!step) {
    return null;
  }

  const status = stringValue(task.status)?.trim().toLowerCase();
  switch (status) {
    case "completed":
      return `\u{2713} ${step}`;
    case "in_progress":
    case "in-progress":
    case "active":
      return `\u{25C9} ${step}`;
    default:
      return `\u{25A1} ${step}`;
  }
}

function responseMessageRolloutItem(
  payload: { [key: string]: JSONValue },
  index: number
): JSONValue | null {
  const outputText = responseContentText(payload.content, "output_text");
  if (outputText) {
    const imageAttachments = imageAttachmentsFromText(outputText, `local-agent-response-${index}`, "message");
    return {
      id: `local-agent-response-${index}`,
      type: "agentMessage",
      text: boundedTailText(outputText),
      phase: "response_item",
      ...(imageAttachments.length > 0 ? { imageAttachments } : {}),
    };
  }

  return null;
}

function imageAttachmentsFromText(
  text: string,
  idPrefix: string,
  source: string
): ThreadImageAttachment[] {
  const paths: string[] = [];
  LOCAL_IMAGE_PATH_RE.lastIndex = 0;
  for (const match of text.matchAll(LOCAL_IMAGE_PATH_RE)) {
    if (match[1]) {
      paths.push(match[1]);
    }
  }
  return imageAttachmentsFromPaths(paths, idPrefix, source);
}

function imageAttachmentsFromPaths(
  imagePaths: string[],
  idPrefix: string,
  source: string
): ThreadImageAttachment[] {
  const seen = new Set<string>();
  const attachments: ThreadImageAttachment[] = [];
  for (const rawPath of imagePaths) {
    const imagePath = rawPath.trim();
    if (!imagePath || seen.has(imagePath)) {
      continue;
    }

    const mimeType = imageMimeTypeForPath(imagePath);
    if (!mimeType) {
      continue;
    }

    seen.add(imagePath);
    attachments.push({
      id: `${idPrefix}-image-${attachments.length + 1}`,
      path: imagePath,
      mimeType,
      filename: path.basename(imagePath),
      source,
    });
  }
  return attachments;
}

function imageMimeTypeForPath(imagePath: string): string | null {
  switch (path.extname(imagePath).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".webp":
      return "image/webp";
    case ".gif":
      return "image/gif";
    case ".heic":
      return "image/heic";
    case ".heif":
      return "image/heif";
    default:
      return null;
  }
}

function responseContentText(
  value: JSONValue | undefined,
  acceptedType: "input_text" | "output_text"
): string | null {
  if (typeof value === "string") {
    return acceptedType === "output_text" ? stripMemoryCitationBlock(value) || null : null;
  }

  if (!Array.isArray(value)) {
    return null;
  }

  const text = value
    .map((entry) => {
      const entryObject = objectValue(entry);
      if (!entryObject || stringValue(entryObject.type) !== acceptedType) {
        return null;
      }
      return stringValue(entryObject.text);
    })
    .filter((entry): entry is string => Boolean(entry))
    .join("\n")
    .trim();

  return stripMemoryCitationBlock(text) || null;
}

function comparableRolloutText(value: string | null): string | null {
  const text = stripMemoryCitationBlock(value ?? "")
    .replace(/\s+/g, " ")
    .trim();
  return text || null;
}

function stripMemoryCitationBlock(value: string): string {
  return value
    .replace(/\n?<oai-mem-citation>[\s\S]*?<\/oai-mem-citation>\s*$/u, "")
    .trimEnd();
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
