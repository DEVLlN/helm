import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import EventEmitter from "node:events";
import { readFile, stat, writeFile } from "node:fs/promises";
import net from "node:net";
import { homedir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import WebSocket, { type RawData } from "ws";

import {
  discoverCodexThread,
  discoverCodexThreads,
  preferredCodexThreadName,
  readCodexThreadLocalTurns,
  resolveCodexThreadRolloutPath,
} from "./codexThreadDiscovery.js";
import { codexProjectNameForPath } from "./codexProjectNames.js";
import {
  deleteCodexThreadReplacement,
  listCodexThreadReplacements,
  resolveCodexThreadReplacement,
} from "./codexThreadReplacementRegistry.js";
import {
  CodexDesktopIpcClient,
  CodexDesktopIpcRequestError,
  codexDesktopIpcSocketPath,
  isCodexDesktopIpcAvailable,
  type CodexDesktopQueuedFollowUp,
  type CodexDesktopQueuedFollowUpsState,
  type CodexDesktopUserInput,
} from "./codexDesktopIpcClient.js";
import { HELM_RUNTIME_LAUNCH_SOURCE } from "./helmManagedLaunch.js";
import {
  launchManagedRuntimeDetached,
  resolveHelmRuntimeWrapperPath,
  resolveUnderlyingRuntimeBinary,
} from "./runtimeShellLauncher.js";
import {
  findMatchingLaunchByThreadID,
  isRuntimeRelayAvailable,
  readRuntimeOutputTail,
  type RuntimeOutputTail,
  type RuntimeLaunchRecord,
} from "./runtimeLaunchRegistry.js";
import { interruptViaRuntimeRelay, sendInputViaRuntimeRelay, sendTextViaRuntimeRelay } from "./runtimeRelayClient.js";
import type {
  ConversationEvent,
  JSONRPCId,
  JSONRPCMessage,
  JSONRPCNotification,
  JSONRPCRequest,
  JSONRPCResponse,
  JSONRPCServerRequest,
  JSONValue,
  ServerRequestEvent,
  StartTurnFileAttachment,
  StartTurnOptions,
  StartTurnImageAttachment,
  ThreadController,
  ThreadSummary,
} from "./types.js";

type PendingRequest = {
  resolve: (value: JSONValue | undefined) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
};

const execFileAsync = promisify(execFile);
const BOOTSTRAP_THREAD_TEXT =
  "Reply with exactly HELM_BOOTSTRAP_OK and do nothing else.";
const BOOTSTRAP_TIMEOUT_MS = 30_000;
const BOOTSTRAP_POLL_INTERVAL_MS = 250;
const MANAGED_SHELL_LAUNCH_TIMEOUT_MS = 30_000;
const SHELL_RELAY_DELIVERY_TIMEOUT_MS = 12_000;
const SHELL_RELAY_DELIVERY_POLL_INTERVAL_MS = 200;
const SHELL_RELAY_QUEUE_ACCEPT_TIMEOUT_MS = 3_000;
const SHELL_RELAY_QUEUE_RETRY_DELAY_MS = 650;
const SHELL_RELAY_QUEUE_ACCEPT_POLL_INTERVAL_MS = 150;
const INTERRUPT_BEFORE_SEND_TIMEOUT_MS = 6_000;
const APP_SERVER_MAX_INBOUND_MESSAGE_BYTES = 128 * 1024 * 1024;
const LOCAL_ROLLOUT_FULLER_TURN_DELTA = 1;
const LOCAL_ROLLOUT_FULLER_ITEM_DELTA = 8;
const CODEX_DESKTOP_CONTROLLER_ID = "codex-desktop";
const CODEX_DESKTOP_CONTROLLER_NAME = "Codex Desktop";
const CODEX_DESKTOP_DUPLICATE_QUEUE_WINDOW_MS = 2_500;
const CODEX_DESKTOP_REFRESH_BUNDLE_ID = "com.openai.codex";
const CODEX_DESKTOP_REFRESH_APP_PATH = "/Applications/Codex.app";
const CODEX_DESKTOP_REFRESH_BOUNCE_URL = "codex://settings";
const CODEX_DESKTOP_REFRESH_AFTER_BOUNCE_MS = 180;
const CODEX_DESKTOP_REFRESH_AFTER_TARGET_MS = 180;

type CodexAppServerSocket = WebSocket;

type EnsureManagedShellThreadResult = {
  threadId: string;
  previousThreadId: string | null;
  replaced: boolean;
  launched: boolean;
  cwd: string;
};

function unixSocketPathFromAppServerEndpoint(endpoint: string): string | null {
  if (!endpoint.startsWith("unix://")) {
    return null;
  }

  const socketPath = decodeURIComponent(endpoint.slice("unix://".length));
  if (!socketPath) {
    throw new Error("Codex app-server unix endpoint requires a socket path");
  }

  return socketPath;
}

type ThreadDeliverySnapshot = {
  hasTurnData: boolean;
  turnCount: number;
  matchingUserTextCount: number;
  updatedAt: number;
  threadStatus: string | null;
  activeTurnId: string | null;
};

type CodexUserInput = CodexDesktopUserInput;

function websocketMessageBuffer(data: RawData | string): Buffer {
  if (typeof data === "string") {
    return Buffer.from(data, "utf8");
  }

  if (Buffer.isBuffer(data)) {
    return data;
  }

  if (data instanceof ArrayBuffer) {
    return Buffer.from(data);
  }

  return Buffer.concat(data);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return isRecord(value) ? value : null;
}

function projectNameValue(thread: Record<string, unknown>): string | null {
  const project = recordValue(thread.project);
  return stringValue(thread.projectName)
    ?? stringValue(thread.project_name)
    ?? stringValue(thread.projectTitle)
    ?? stringValue(thread.projectDisplayName)
    ?? stringValue(thread.workspaceName)
    ?? stringValue(thread.workspaceDisplayName)
    ?? (project
      ? stringValue(project.name)
        ?? stringValue(project.title)
        ?? stringValue(project.displayName)
      : null);
}

function codexStatePath(): string {
  return path.join(homedir(), ".codex", "state_5.sqlite");
}

function codexGlobalStatePath(): string {
  return path.join(homedir(), ".codex", ".codex-global-state.json");
}

function normalizeUpdatedAt(value: number | undefined): number {
  if (!value || !Number.isFinite(value)) {
    return Date.now();
  }

  return value > 1_000_000_000_000 ? value : value * 1000;
}

function inferredStatusForUpdatedAt(
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

function normalizedThreadSummaryPreview(
  preview: string | null | undefined,
  name: string | null | undefined,
  status: string,
  fallbackPreview: string | null | undefined = null
): string {
  const trimmedPreview = String(preview ?? "").trim();
  const trimmedFallback = String(fallbackPreview ?? "").trim();
  const trimmedName = String(name ?? "").trim();
  const normalizedStatus = status.trim().toLowerCase();

  const titleEcho = (candidate: string): boolean =>
    candidate.length > 0
    && trimmedName.length > 0
    && candidate === trimmedName;

  const titleEchoShouldYieldPlaceholder = (candidate: string): boolean =>
    (normalizedStatus === "running" || normalizedStatus === "idle")
    && titleEcho(candidate);

  if (trimmedPreview && !titleEchoShouldYieldPlaceholder(trimmedPreview)) {
    return trimmedPreview;
  }

  if (trimmedFallback && !titleEchoShouldYieldPlaceholder(trimmedFallback)) {
    return trimmedFallback;
  }

  if (normalizedStatus === "idle" && (titleEcho(trimmedPreview) || titleEcho(trimmedFallback))) {
    return "No activity yet.";
  }

  return normalizedStatus === "running" ? "Waiting for output..." : "";
}

function titleEchoSummaryShouldPreferIdle(
  preview: string | null | undefined,
  name: string | null | undefined,
  fallbackPreview: string | null | undefined = null
): boolean {
  const trimmedPreview = String(preview ?? "").trim();
  const trimmedFallback = String(fallbackPreview ?? "").trim();
  const trimmedName = String(name ?? "").trim();
  if (!trimmedName) {
    return false;
  }

  return (
    (trimmedPreview.length === 0 && trimmedFallback.length === 0) ||
    trimmedPreview === trimmedName ||
    trimmedFallback === trimmedName
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function threadStatusType(value: unknown): string | null {
  if (typeof value === "string") {
    const normalized = value.trim();
    return normalized.length > 0 ? normalized : null;
  }

  if (isRecord(value) && typeof value.type === "string") {
    const normalized = value.type.trim();
    return normalized.length > 0 ? normalized : null;
  }

  return null;
}

function normalizedAppServerThreadStatus(
  value: unknown,
  updatedAt: number,
  options: {
    preferRecentIdle?: boolean;
  } = {}
): string {
  const rawStatus = threadStatusType(value)?.toLowerCase() ?? "unknown";

  switch (rawStatus) {
    case "running":
    case "idle":
    case "blocked":
    case "completed":
    case "unknown":
      return rawStatus;
    case "waitingapproval":
    case "waiting_approval":
    case "waiting-approval":
      return "waitingApproval";
    case "notloaded":
    case "not_loaded":
    case "not-loaded":
      return inferredStatusForUpdatedAt(updatedAt, options);
    case "loaded":
      return "running";
    default:
      if (rawStatus.includes("waiting") && rawStatus.includes("approval")) {
        return "waitingApproval";
      }
      if (rawStatus.includes("running")) {
        return "running";
      }
      if (rawStatus.includes("idle")) {
        return "idle";
      }
      if (rawStatus.includes("blocked")) {
        return "blocked";
      }
      if (rawStatus.includes("completed")) {
        return "completed";
      }
      return rawStatus;
  }
}

function stringArrayValue(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function threadIdFromPayload(value: unknown): string | null {
  if (!isRecord(value)) {
    return null;
  }

  const candidates = [
    value.threadId,
    value.thread_id,
    value.conversationId,
    value.conversation_id,
  ];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate.trim();
    }
  }

  const thread = value.thread;
  if (isRecord(thread)) {
    const threadId = threadIdFromPayload(thread);
    if (threadId) {
      return threadId;
    }
  }

  const turn = value.turn;
  if (isRecord(turn)) {
    const turnThreadId = threadIdFromPayload(turn);
    if (turnThreadId) {
      return turnThreadId;
    }
  }

  return null;
}

function normalizeWorkspaceRoot(value: string): string {
  const resolved = path.resolve(value);
  return resolved.endsWith(path.sep) ? resolved.slice(0, -path.sep.length) : resolved;
}

function threadMatchesWorkspaceRoot(thread: ThreadSummary, workspaceRoot: string): boolean {
  const normalizedRoot = normalizeWorkspaceRoot(workspaceRoot);
  const candidates = [thread.workspacePath, thread.cwd]
    .filter((entry): entry is string => typeof entry === "string" && entry.trim().length > 0)
    .map((entry) => normalizeWorkspaceRoot(entry));

  return candidates.some((candidate) => {
    return candidate === normalizedRoot || candidate.startsWith(`${normalizedRoot}${path.sep}`);
  });
}

function isResponse(message: unknown): message is JSONRPCResponse {
  return (
    isRecord(message) &&
    "id" in message &&
    ("result" in message || "error" in message)
  );
}

function isNotification(message: unknown): message is JSONRPCNotification {
  return (
    isRecord(message) &&
    typeof message.method === "string" &&
    !("id" in message)
  );
}

function isServerRequest(message: unknown): message is JSONRPCServerRequest {
  return (
    isRecord(message) &&
    typeof message.method === "string" &&
    "id" in message &&
    !("result" in message) &&
    !("error" in message)
  );
}

function normalizeThreadStatus(value: unknown): string | null {
  if (typeof value === "string" && value.length > 0) {
    if (value === "active") {
      return "running";
    }
    return value;
  }

  if (isRecord(value) && typeof value.type === "string" && value.type.length > 0) {
    if (value.type === "active") {
      return "running";
    }
    return value.type;
  }

  return null;
}

function activeTurnIdFromTurns(turns: unknown[]): string | null {
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index];
    const status = isRecord(turn) && typeof turn.status === "string"
      ? turn.status.trim().toLowerCase()
      : "";
    if (
      isRecord(turn) &&
      typeof turn.id === "string" &&
      turn.id.length > 0 &&
      (status === "inprogress" || status === "running" || status === "active")
    ) {
      return turn.id;
    }
  }

  return null;
}

function countMatchingUserMessages(turns: unknown[], text: string): number {
  const trimmed = text.trim();
  if (!trimmed) {
    return 0;
  }

  let count = 0;
  for (const turn of turns) {
    if (!isRecord(turn) || !Array.isArray(turn.items)) {
      continue;
    }

    for (const item of turn.items) {
      if (
        !isRecord(item) ||
        (item.type !== "userMessage" && item.type !== "steeringUserMessage")
      ) {
        continue;
      }

      const rawText = matchingUserItemText(item);
      if (rawText.trim() === trimmed) {
        count += 1;
      }
    }
  }

  return count;
}

function matchingUserItemText(item: Record<string, unknown>): string {
  const directText =
    stringValue(item.rawText) ??
    stringValue(item.detail) ??
    stringValue(item.text) ??
    stringValue(item.title) ??
    textFromContent(item.content) ??
    textFromCodexInput(item.input) ??
    textFromRestoreMessage(item.restoreMessage);

  return directText ?? "";
}

function textFromContent(value: unknown): string | null {
  if (!isRecord(value)) {
    return null;
  }

  return stringValue(value.text) ?? null;
}

function textFromRestoreMessage(value: unknown): string | null {
  if (!isRecord(value)) {
    return null;
  }

  return stringValue(value.text) ?? textFromContent(value.context) ?? null;
}

function textFromCodexInput(value: unknown): string | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const parts = value.flatMap((entry) => {
    if (!isRecord(entry) || entry.type !== "text") {
      return [];
    }

    const text = stringValue(entry.text);
    return text ? [text] : [];
  });

  return parts.length > 0 ? parts.join("\n") : null;
}

function normalizedTerminalComparisonText(text: string): string {
  return text.replace(/\s+/g, " ").trim().toLowerCase();
}

function tailContainsQueuedFollowUp(text: string, queuedText: string): boolean {
  const normalizedTail = normalizedTerminalComparisonText(text);
  const compactedTail = normalizedTail.replace(/\s+/g, "");
  const normalizedQueuedText = normalizedTerminalComparisonText(queuedText);

  return (
    compactedTail.includes("queuedfollow-upmessages") ||
    compactedTail.includes("queuedfollowupmessages") ||
    compactedTail.includes("messagestobesubmittedafternexttoolcall") ||
    compactedTail.includes("messagestobesubmittedafterthenexttoolcall")
  ) && normalizedTail.includes(normalizedQueuedText);
}

function terminalTailDelta(previousText: string | null, nextText: string): string {
  if (!previousText || !nextText) {
    return nextText;
  }
  if (nextText === previousText) {
    return "";
  }
  if (nextText.startsWith(previousText)) {
    return nextText.slice(previousText.length);
  }

  const maxOverlap = Math.min(previousText.length, nextText.length);
  for (let length = maxOverlap; length > 0; length -= 1) {
    if (previousText.slice(previousText.length - length) === nextText.slice(0, length)) {
      return nextText.slice(length);
    }
  }

  return nextText;
}

const CODEX_CLI_PLACEHOLDER_DRAFT_PATTERNS = [
  /^find\s+and\s+fix\s+a\s+bug\s+in\s+@filename$/i,
  /^write\s+tests\s+for\s+@filename$/i,
] as const;

function isCodexCLIPlaceholderDraft(text: string): boolean {
  const normalized = text
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  return CODEX_CLI_PLACEHOLDER_DRAFT_PATTERNS.some((pattern) => pattern.test(normalized));
}

export function currentPromptDraftFromTerminalTail(text: string | null): string | null {
  if (!text) {
    return null;
  }

  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index] ?? "";
    const promptIndex = line.lastIndexOf("›");
    if (promptIndex === -1) {
      continue;
    }

    const promptPrefix = line.slice(0, promptIndex).replace(/\u00a0/g, " ").trim();
    if (promptPrefix) {
      continue;
    }

    const normalizedPromptLine = line
      .slice(promptIndex + 1)
      .replace(/\u00a0/g, " ")
      .trim();
    if (!normalizedPromptLine) {
      continue;
    }

    const draft = normalizedPromptLine
      .replace(
        /\s{2,}(?:gpt-|o\d|claude|codex|Fast\s+(?:on|off)|Context\s+\[|\d+K\s+window|5h\s+\d+%|weekly\s+\d+%).*$/i,
        ""
      )
      .replace(/\s+shift\s+\+.*edit\s+last\s+queued\s+message.*$/i, "")
      .trim();

    if (!draft || isCodexCLIPlaceholderDraft(draft)) {
      continue;
    }

    return draft;
  }

  return null;
}

function runtimeTailLooksQueueable(tail: RuntimeOutputTail | null): boolean {
  if (!tail || Date.now() - tail.updatedAt > 30_000) {
    return false;
  }

  const normalized = tail.text
    .replace(/\u001B\[[0-9;?]*[A-Za-z]/g, "")
    .replace(/\r\n?/g, "\n")
    .replace(/\u00a0/g, " ");
  const lastPromptIndex = normalized.lastIndexOf("›");
  const statusPattern =
    /(?:^|\n)\s*[•.\-*]?\s*(?:Working(?:\s*(?:\(|·|\b|for))|Waiting(?:\s+for|\b)|Exploring\b|Queued\s*follow-?up\s*messages|Queuedfollow-?upmessages|Messages\s+to\s+be\s+submitted\s+after\s+(?:the\s+)?next\s+tool\s+call)/gi;

  let latestStatusIndex = -1;
  for (const match of normalized.matchAll(statusPattern)) {
    latestStatusIndex = match.index ?? latestStatusIndex;
  }

  return latestStatusIndex !== -1 && lastPromptIndex < latestStatusIndex;
}

export class CodexAppServerClient extends EventEmitter {
  private socket: CodexAppServerSocket | null = null;
  private connectInFlight: Promise<void> | null = null;
  private initialized = false;
  private nextId = 1;
  private readonly pending = new Map<JSONRPCId, PendingRequest>();
  private readonly managedShellEnsures = new Map<string, Promise<EnsureManagedShellThreadResult>>();
  private codexDesktopQueueMutation: Promise<unknown> = Promise.resolve();
  private readonly codexDesktopAppServerRefreshThreads = new Set<string>();

  constructor(private readonly endpoint: string) {
    super();
  }

  async connect(): Promise<void> {
    if (this.socket?.readyState === WebSocket.OPEN) {
      return;
    }

    if (this.connectInFlight) {
      await this.connectInFlight;
      return;
    }

    this.connectInFlight = this.openConnection();

    try {
      await this.connectInFlight;
    } finally {
      this.connectInFlight = null;
    }
  }

  private async openConnection(): Promise<void> {
    const socket = this.createSocket();
    this.socket = socket;

    await new Promise<void>((resolve, reject) => {
      const cleanup = () => {
        socket.off("open", handleOpen);
        socket.off("error", handleError);
      };

      const handleOpen = () => {
        cleanup();
        resolve();
      };

      const handleError = (error: Error) => {
        cleanup();
        reject(error);
      };

      socket.once("open", handleOpen);
      socket.once("error", handleError);
    });

    socket.on("message", (data) => {
      const payload = websocketMessageBuffer(data);
      if (payload.length > APP_SERVER_MAX_INBOUND_MESSAGE_BYTES) {
        socket.close(1009, "Codex app-server message too large");
        this.rejectPendingRequests(new Error(
          `Codex app-server message too large: ${payload.length} bytes`
        ));
        return;
      }

      const text = payload.toString("utf8");
      try {
        const message = JSON.parse(text) as unknown;
        this.handleMessage(message);
      } catch (error) {
        socket.close(1003, "Invalid Codex app-server JSON");
        this.rejectPendingRequests(error instanceof Error ? error : new Error(String(error)));
      }
    });

    socket.on("error", (error) => {
      this.rejectPendingRequests(error instanceof Error ? error : new Error(String(error)));
      socket.close();
    });

    socket.on("close", () => {
      if (this.socket === socket) {
        this.socket = null;
      }
      this.initialized = false;
      this.rejectPendingRequests(new Error("Codex app-server socket closed"));
      this.emit("disconnect");
    });

    await this.initialize();
    this.initialized = true;
  }

  private createSocket(): CodexAppServerSocket {
    const unixSocketPath = unixSocketPathFromAppServerEndpoint(this.endpoint);
    if (unixSocketPath) {
      return new WebSocket("ws://localhost/", {
        createConnection: () => net.createConnection(unixSocketPath),
        maxPayload: APP_SERVER_MAX_INBOUND_MESSAGE_BYTES,
        perMessageDeflate: false,
      });
    }

    return new WebSocket(this.endpoint, {
      maxPayload: APP_SERVER_MAX_INBOUND_MESSAGE_BYTES,
      perMessageDeflate: false,
    });
  }

  private async initialize(): Promise<void> {
    await this.sendRequest(
      "initialize",
      {
        clientInfo: {
          name: "CodexVoiceRemoteBridge",
          title: null,
          version: "0.1.0",
        },
        capabilities: {
          experimentalApi: true,
        },
      }
    );
  }

  private handleMessage(message: unknown): void {
    if (isResponse(message)) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        return;
      }

      this.pending.delete(message.id);
      clearTimeout(pending.timeout);

      if (message.error) {
        pending.reject(new Error(message.error.message));
        return;
      }

      pending.resolve(message.result);
      return;
    }

    if (isNotification(message)) {
      const event: ConversationEvent = {
        method: message.method,
        params: message.params,
      };
      this.handleCodexDesktopAppServerRefreshEvent(event);
      this.emit("event", event);
      return;
    }

    if (isServerRequest(message)) {
      const request: ServerRequestEvent = {
        id: message.id,
        method: message.method,
        params: message.params,
      };
      this.emit("serverRequest", request);
    }
  }

  private async request(method: string, params?: JSONValue): Promise<JSONValue | undefined> {
    await this.connect();
    return await this.sendRequest(method, params);
  }

  private async sendRequest(method: string, params?: JSONValue): Promise<JSONValue | undefined> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Codex app-server socket is not connected");
    }

    const id = this.nextId++;
    const request: JSONRPCRequest = {
      id,
      method,
      params,
    };

    const payload = JSON.stringify(request);
    this.socket.send(payload);

    return await new Promise<JSONValue | undefined>((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`Request timed out: ${method}`));
        }
      }, 30_000);
      this.pending.set(id, { resolve, reject, timeout });
    });
  }

  private rejectPendingRequests(error: Error): void {
    for (const [id, pending] of this.pending.entries()) {
      this.pending.delete(id);
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
  }

  async listThreads(): Promise<ThreadSummary[]> {
    const discoveredThreads = await discoverCodexThreads(50);
    let remoteThreads: ThreadSummary[] = [];
    if (this.isReadyForRequests() || discoveredThreads.length === 0) {
      try {
      remoteThreads = await this.listThreadsFromAppServer();
      } catch (error) {
        console.warn(`[bridge] Codex thread/list failed; using local discovery only: ${errorMessage(error)}`);
      }
    }

    const merged = new Map<string, ThreadSummary>();
    const replacedThreadIDs = new Set(
      listCodexThreadReplacements("codex").map((record) => record.oldThreadId)
    );

    for (const thread of discoveredThreads) {
      if (replacedThreadIDs.has(thread.id)) {
        continue;
      }
      merged.set(thread.id, thread);
    }

    for (const thread of remoteThreads) {
      if (replacedThreadIDs.has(thread.id)) {
        continue;
      }
      const discovered = merged.get(thread.id);
      merged.set(thread.id, this.mergeThreadSummary(thread, discovered ?? null));
    }

    const threads = await this.applyCodexDesktopWorkspaceFocus(Array.from(merged.values()));
    return threads.sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt);
  }

  private isReadyForRequests(): boolean {
    return this.socket?.readyState === WebSocket.OPEN && this.initialized;
  }

  private mergeThreadSummary(
    thread: ThreadSummary,
    discovered: ThreadSummary | null
  ): ThreadSummary {
    const updatedAt = normalizeUpdatedAt(thread.updatedAt || discovered?.updatedAt || 0);
    const remoteStatus = thread.status && thread.status !== "unknown" ? thread.status : null;
    const preferredName = preferredCodexThreadName(thread.name, discovered?.name);
    const status = remoteStatus
      ?? discovered?.status
      ?? inferredStatusForUpdatedAt(updatedAt, {
        preferRecentIdle: titleEchoSummaryShouldPreferIdle(
          thread.preview,
          preferredName,
          discovered?.preview ?? null
        ),
      });
    return {
      ...thread,
      name: preferredName,
      preview: normalizedThreadSummaryPreview(
        thread.preview,
        preferredName,
        status,
        discovered?.preview ?? null
      ),
      cwd: thread.cwd || discovered?.cwd || "",
      workspacePath: thread.workspacePath ?? discovered?.workspacePath ?? null,
      projectName: thread.projectName
        ?? discovered?.projectName
        ?? codexProjectNameForPath(thread.workspacePath ?? discovered?.workspacePath ?? thread.cwd ?? discovered?.cwd),
      status,
      updatedAt,
      sourceKind: thread.sourceKind ?? discovered?.sourceKind ?? null,
      launchSource: thread.launchSource ?? discovered?.launchSource ?? null,
      controller: thread.controller ?? discovered?.controller ?? null,
    };
  }

  private async listThreadsFromAppServer(): Promise<ThreadSummary[]> {
    let loadedThreadIDs = new Set<string>();
    try {
      loadedThreadIDs = await this.listLoadedThreads();
    } catch (error) {
      console.warn(`[bridge] Codex thread/loaded/list failed: ${errorMessage(error)}`);
    }

    const result = await this.request("thread/list", {
      archived: false,
      limit: 25,
      sourceKinds: ["appServer", "cli", "vscode"],
    });

    const root = (result ?? {}) as {
      data?: Array<Record<string, JSONValue>>;
      threads?: Array<Record<string, JSONValue>>;
    };
    const threads = Array.isArray(root.data)
      ? root.data.filter((entry): entry is Record<string, JSONValue> => isRecord(entry))
      : Array.isArray(root.threads)
        ? root.threads.filter((entry): entry is Record<string, JSONValue> => isRecord(entry))
        : [];

    return threads.map((thread) => {
      const updatedAt = normalizeUpdatedAt(Number(thread.updatedAt ?? 0));
      const rawName = stringValue(thread.name);
      const name = rawName || stringValue(thread.title);
      const preview = stringValue(thread.preview);
      const normalizedStatus = normalizedAppServerThreadStatus(thread.status, updatedAt, {
        preferRecentIdle: titleEchoSummaryShouldPreferIdle(preview, name),
      });
      const threadID = String(thread.id ?? "");
      return {
        id: threadID,
        name,
        preview: normalizedThreadSummaryPreview(
          preview,
          name,
          normalizedStatus
        ),
        cwd: String(thread.cwd ?? ""),
        projectName: projectNameValue(thread) ?? codexProjectNameForPath(String(thread.workspacePath ?? thread.cwd ?? "")),
        status: normalizedStatus,
        updatedAt,
        sourceKind: stringValue(thread.sourceKind) ?? stringValue(thread.source),
        launchSource: stringValue(thread.launchSource),
        backendId: "codex",
        backendLabel: "Codex",
        backendKind: "codex",
        controller: loadedThreadIDs.has(threadID)
          ? codexDesktopThreadController(Date.now())
          : null,
      };
    });
  }

  private async applyCodexDesktopWorkspaceFocus(threads: ThreadSummary[]): Promise<ThreadSummary[]> {
    if (threads.length === 0) {
      return threads;
    }

    let activeWorkspaceRoots: string[] = [];
    try {
      activeWorkspaceRoots = await this.readCodexDesktopActiveWorkspaceRoots();
    } catch (error) {
      console.warn(
        `[bridge] Failed to read Codex active workspace roots: ${errorMessage(error)}`
      );
      return threads;
    }

    if (activeWorkspaceRoots.length === 0) {
      return threads;
    }

    const candidateThreadIDs = new Set<string>();
    for (const workspaceRoot of activeWorkspaceRoots) {
      const alreadyControlled = threads.some((thread) => {
        return thread.controller?.clientId === CODEX_DESKTOP_CONTROLLER_ID
          && threadMatchesWorkspaceRoot(thread, workspaceRoot);
      });
      if (alreadyControlled) {
        continue;
      }

      const candidate = threads
        .filter((thread) => {
          const sourceKind = (thread.sourceKind ?? "").trim().toLowerCase();
          return (
            (sourceKind === "vscode" || sourceKind === "appserver")
            && threadMatchesWorkspaceRoot(thread, workspaceRoot)
          );
        })
        .sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt)[0];
      if (candidate) {
        candidateThreadIDs.add(candidate.id);
      }
    }

    if (candidateThreadIDs.size === 0) {
      return threads;
    }

    const now = Date.now();
    return threads.map((thread) => {
      if (!candidateThreadIDs.has(thread.id) || thread.controller != null) {
        return thread;
      }
      return {
        ...thread,
        controller: codexDesktopThreadController(now),
      };
    });
  }

  async startThread(input: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
  } = {}): Promise<JSONValue | undefined> {
    return await this.request("thread/start", {
      cwd: input.cwd ?? null,
      model: input.model ?? null,
      baseInstructions: input.baseInstructions ?? null,
      ephemeral: false,
      experimentalRawEvents: false,
      persistExtendedHistory: true,
    });
  }

  async readThread(
    threadId: string,
    options: {
      includeTurns?: boolean;
      allowTurnlessFallback?: boolean;
    } = {}
  ): Promise<JSONValue | undefined> {
    const includeTurns = options.includeTurns ?? true;
    if (includeTurns) {
      const localFirstFallback = await this.localThreadReadFallback(threadId, true);
      if (localFirstFallback && this.shouldUseLocalThreadReadBeforeAppServer(localFirstFallback)) {
        return localFirstFallback;
      }
    }

    try {
      const result = await this.request("thread/read", {
        threadId,
        includeTurns,
      });
      if (includeTurns) {
        const fullerLocalFallback = await this.fullerLocalThreadReadFallback(threadId, result);
        if (fullerLocalFallback) {
          return fullerLocalFallback;
        }
      }
      return result;
    } catch (error) {
      const localFallback = includeTurns
        ? await this.localThreadReadFallback(threadId, true)
        : undefined;
      const shouldFallback =
        includeTurns
        && options.allowTurnlessFallback
        && this.shouldFallbackToTurnlessThreadRead(error);
      if (shouldFallback) {
        try {
          return await this.request("thread/read", {
            threadId,
            includeTurns: false,
          });
        } catch (fallbackError) {
          const localMetadataFallback = await this.localThreadReadFallback(threadId, false);
          if (localMetadataFallback && this.shouldFallbackToLocalThreadRead(fallbackError)) {
            console.warn(
              `[bridge] Codex turnless thread/read failed for ${threadId}; using local metadata fallback: ${errorMessage(fallbackError)}`
            );
            return localMetadataFallback;
          }
          throw fallbackError;
        }
      }

      if (
        localFallback
        && this.shouldFallbackToLocalThreadRead(error)
        && this.threadReadHasTurns(localFallback)
      ) {
        console.warn(
          `[bridge] Codex thread/read failed for ${threadId}; using local rollout fallback: ${errorMessage(error)}`
        );
        return localFallback;
      }

      if (!shouldFallback) {
        const fallback = localFallback ?? await this.localThreadReadFallback(threadId, includeTurns);
        if (fallback && this.shouldFallbackToLocalThreadRead(error)) {
          console.warn(
            `[bridge] Codex thread/read failed for ${threadId}; using local metadata fallback: ${errorMessage(error)}`
          );
          return fallback;
        }
        throw error;
      }
    }
  }

  private shouldUseLocalThreadReadBeforeAppServer(value: JSONValue | undefined): boolean {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return false;
    }

    const thread = value.thread;
    if (!thread || typeof thread !== "object" || Array.isArray(thread)) {
      return false;
    }

    const sourceKind = typeof thread.sourceKind === "string"
      ? thread.sourceKind.trim().toLowerCase()
      : "";
    return (sourceKind === "cli" || sourceKind === "vscode") && this.threadReadHasTurns(value);
  }

  private async fullerLocalThreadReadFallback(
    threadId: string,
    appServerResult: JSONValue | undefined
  ): Promise<JSONValue | undefined> {
    const appServerMetrics = this.threadReadMetrics(appServerResult);
    const localFallback = await this.localThreadReadFallback(threadId, true);
    const localMetrics = this.threadReadMetrics(localFallback);
    if (
      localMetrics.turnCount <= appServerMetrics.turnCount + LOCAL_ROLLOUT_FULLER_TURN_DELTA
      && localMetrics.itemCount <= appServerMetrics.itemCount + LOCAL_ROLLOUT_FULLER_ITEM_DELTA
    ) {
      return undefined;
    }

    console.warn(
      `[bridge] Codex thread/read returned ${appServerMetrics.turnCount} turns/${appServerMetrics.itemCount} items for ${threadId}; using fuller local rollout fallback with ${localMetrics.turnCount} turns/${localMetrics.itemCount} items`
    );
    return localFallback;
  }

  private shouldFallbackToTurnlessThreadRead(error: unknown): boolean {
    const message = errorMessage(error).toLowerCase();
    return message.includes("max payload size exceeded")
      || message.includes("message too large")
      || message.includes("socket closed")
      || message.includes("failed to locate rollout");
  }

  private shouldFallbackToLocalThreadRead(error: unknown): boolean {
    const message = errorMessage(error).toLowerCase();
    return this.shouldFallbackToTurnlessThreadRead(error)
      || message.includes("thread not found")
      || message.includes("request timed out: thread/read");
  }

  private async localThreadReadFallback(
    threadId: string,
    includeTurns: boolean
  ): Promise<JSONValue | undefined> {
    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      return undefined;
    }

    const turns = includeTurns ? await readCodexThreadLocalTurns(threadId) : [];
    const updatedAt = await this.localThreadReadUpdatedAt(threadId, thread.updatedAt);
    return {
      thread: {
        id: thread.id,
        name: thread.name,
        preview: thread.preview,
        cwd: thread.cwd,
        status: thread.status,
        updatedAt,
        sourceKind: thread.sourceKind,
        ...(includeTurns ? { turns } : {}),
      },
    };
  }

  private async localThreadReadUpdatedAt(
    threadId: string,
    fallbackUpdatedAt: number
  ): Promise<number> {
    try {
      const rolloutPath = await resolveCodexThreadRolloutPath(threadId);
      if (!rolloutPath) {
        return fallbackUpdatedAt;
      }

      const rolloutStats = await stat(rolloutPath);
      return Math.max(fallbackUpdatedAt, rolloutStats.mtimeMs);
    } catch {
      return fallbackUpdatedAt;
    }
  }

  private threadReadHasTurns(value: JSONValue): boolean {
    return this.threadReadMetrics(value).turnCount > 0;
  }

  private threadReadMetrics(value: JSONValue | undefined): { turnCount: number; itemCount: number } {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { turnCount: 0, itemCount: 0 };
    }

    const thread = value.thread;
    if (!thread || typeof thread !== "object" || Array.isArray(thread)) {
      return { turnCount: 0, itemCount: 0 };
    }

    if (!Array.isArray(thread.turns)) {
      return { turnCount: 0, itemCount: 0 };
    }

    const itemCount = thread.turns.reduce<number>((count, turn) => {
      if (!turn || typeof turn !== "object" || Array.isArray(turn)) {
        return count;
      }

      const items = turn.items;
      return count + (Array.isArray(items) ? items.length : 0);
    }, 0);
    return { turnCount: thread.turns.length, itemCount };
  }

  private async readThreadMetadata(threadId: string): Promise<JSONValue | undefined> {
    return await this.request("thread/read", {
      threadId,
      includeTurns: false,
    });
  }

  async forkThread(input: {
    threadId: string;
    cwd?: string;
    model?: string;
    baseInstructions?: string;
  }): Promise<JSONValue | undefined> {
    return await this.request("thread/fork", {
      threadId: input.threadId,
      cwd: input.cwd ?? null,
      model: input.model ?? null,
      baseInstructions: input.baseInstructions ?? null,
      ephemeral: false,
      persistExtendedHistory: true,
    });
  }

  async archiveThread(threadId: string): Promise<void> {
    try {
      await this.request("thread/archive", {
        threadId,
      });
    } catch {
      await archiveThreadInStateDatabase(threadId);
    }
  }

  async ensureManagedShellThread(
    threadId: string,
    options: {
      launchManagedShell?: boolean;
      preferVisibleLaunch?: boolean;
    } = {}
  ): Promise<EnsureManagedShellThreadResult> {
    const coordinationKey = threadId;
    const existing = this.managedShellEnsures.get(coordinationKey);
    if (existing) {
      return await existing;
    }

    const task = (async () => {
      const launchManagedShell = options.launchManagedShell ?? false;
      const preferVisibleLaunch = options.preferVisibleLaunch ?? false;
      const resolvedReplacement = await this.resolveUsableHistoricalReplacement(threadId);
      let canonicalThreadId = resolvedReplacement?.newThreadId ?? threadId;
      let previousThreadId = resolvedReplacement?.oldThreadId ?? null;
      let replaced = resolvedReplacement !== null;

      let thread = await this.loadThreadSummary(canonicalThreadId);
      if (!thread && canonicalThreadId !== threadId) {
        canonicalThreadId = threadId;
        thread = await this.loadThreadSummary(canonicalThreadId);
        previousThreadId = null;
        replaced = false;
      }
      if (!thread) {
        throw new Error(`thread not found: ${threadId}`);
      }

      if (codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
        return {
          threadId: canonicalThreadId,
          previousThreadId,
          replaced,
          launched: false,
          cwd: thread.cwd,
        };
      }

      const exactLaunch = findMatchingLaunchByThreadID("codex", canonicalThreadId);
      const canAdoptHistoricalThread =
        launchManagedShell
        && codexSourceKindSupportsManagedShellAdoption(thread.sourceKind);
      const shouldEnsureManagedShell =
        launchManagedShell
        && (Boolean(exactLaunch) || replaced || canAdoptHistoricalThread);
      let launched = false;
      const needsHistoricalTakeover = !exactLaunch && !replaced && canAdoptHistoricalThread;

      if (needsHistoricalTakeover) {
        launched = await this.launchManagedShellResume(canonicalThreadId, thread.cwd, {
          visibleTerminal: preferVisibleLaunch,
        });
        await this.notifyHistoricalThreadManagedTakeover(canonicalThreadId);
      } else if (shouldEnsureManagedShell) {
        launched = await this.launchManagedShellResume(canonicalThreadId, thread.cwd, {
          visibleTerminal: preferVisibleLaunch,
        });
      }

      return {
        threadId: canonicalThreadId,
        previousThreadId,
        replaced,
        launched,
        cwd: thread.cwd,
      };
    })();

    this.managedShellEnsures.set(coordinationKey, task);
    try {
      return await task;
    } finally {
      if (this.managedShellEnsures.get(coordinationKey) === task) {
        this.managedShellEnsures.delete(coordinationKey);
      }
    }
  }

  async bootstrapManagedShellThread(input: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
  } = {}): Promise<{ threadId: string; cwd: string; mode: string }> {
    const started = await this.startThread(input);
    const threadId = this.extractThreadId(started);
    if (!threadId) {
      throw new Error("Codex bootstrap did not return a thread id.");
    }

    await this.request("turn/start", {
      threadId,
      input: [
        {
          type: "text",
          text: BOOTSTRAP_THREAD_TEXT,
          text_elements: [],
        },
      ],
    });

    await this.waitForThreadTurnCount(threadId, 1);
    await this.request("thread/rollback", {
      threadId,
      numTurns: 1,
    });
    await scrubBootstrapThreadMetadata(threadId);
    await this.waitForDiscoveredThread(threadId);

    return {
      threadId,
      cwd: input.cwd ?? "",
      mode: "rollbackBootstrap",
    };
  }

  async startManagedShellThread(input: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
    reasoningEffort?: string;
    codexFastMode?: boolean;
  } = {}): Promise<JSONValue | undefined> {
    const bootstrapped = await this.bootstrapManagedShellThread({
      cwd: input.cwd,
      model: input.model,
      baseInstructions: input.baseInstructions,
    });

    await this.launchManagedShellResume(bootstrapped.threadId, bootstrapped.cwd, {
      extraArgs: codexManagedResumeArgs(bootstrapped.threadId, bootstrapped.cwd, input),
    });

    return await this.readThread(bootstrapped.threadId, { includeTurns: false });
  }

  async startTurn(threadId: string, text: string, options: StartTurnOptions = {}): Promise<JSONValue | undefined> {
    const effectiveText = this.textWithFileAttachments(text, options.fileAttachments ?? []);
    let appServerStartError: Error | null = null;
    let appServerSteerError: Error | null = null;
    let shellRelayError: Error | null = null;
    const hasImageAttachments = Boolean(options.imageAttachments?.length);
    const queueSafeText = this.textWithImageAttachments(effectiveText, options.imageAttachments ?? []);
    const shellRelayText = queueSafeText;
    let attemptedShellRelay = false;
    const queueDeliveryRequested = options.deliveryMode === "queue";
    const steerDeliveryRequested = options.deliveryMode === "steer" && !hasImageAttachments;
    const activeDeliveryRequested = queueDeliveryRequested || steerDeliveryRequested;
    const activeDeliveryText = queueDeliveryRequested ? queueSafeText : effectiveText;
    const deliveryThread = await this.loadThreadDeliverySummary(threadId);
    const activeDeliveryThread = activeDeliveryRequested ? deliveryThread : null;
    const activeDeliveryUsesSharedDesktopSurface =
      activeDeliveryThread ? codexSourceKindUsesSharedDesktopSurface(activeDeliveryThread.sourceKind) : false;
    const activeDeliverySnapshot = activeDeliveryRequested
      ? await this.readThreadDeliverySnapshot(threadId, activeDeliveryText)
      : null;
    const activeDeliveryLaunch = activeDeliveryRequested ? findMatchingLaunchByThreadID("codex", threadId) : null;
    const activeDeliveryHasRuntimeRelay = isRuntimeRelayAvailable(activeDeliveryLaunch);
    const activeDeliveryTerminalLooksQueueable =
      activeDeliveryHasRuntimeRelay && runtimeTailLooksQueueable(readRuntimeOutputTail(activeDeliveryLaunch));
    const activeDeliveryNeedsRunningTurnSteer =
      activeDeliverySnapshot?.threadStatus === "running"
      || Boolean(activeDeliverySnapshot?.activeTurnId)
      || activeDeliveryTerminalLooksQueueable;

    const desktopIpcDeliveryThread = deliveryThread;
    const desktopIpcDeliveryBaseline = desktopIpcDeliveryThread
      && codexSourceKindUsesSharedDesktopSurface(desktopIpcDeliveryThread.sourceKind)
      ? activeDeliverySnapshot
        ?? await this.readThreadDeliverySnapshot(threadId, activeDeliveryText)
        ?? this.threadDeliverySnapshotFromSummary(desktopIpcDeliveryThread)
      : null;
    if (
      desktopIpcDeliveryThread
      && codexSourceKindUsesSharedDesktopSurface(desktopIpcDeliveryThread.sourceKind)
    ) {
      try {
        if (queueDeliveryRequested) {
          if (!hasImageAttachments && desktopIpcDeliveryBaseline?.threadStatus !== "running") {
            return await this.startTurnViaCodexDesktopIpc(
              threadId,
              activeDeliveryText,
              options,
              desktopIpcDeliveryBaseline
            );
          }
          return await this.enqueueTurnViaCodexDesktopIpc(
            threadId,
            queueSafeText,
            options,
            desktopIpcDeliveryThread
          );
        }
        if (steerDeliveryRequested) {
          return await this.steerTurnViaCodexDesktopIpc(
            threadId,
            effectiveText,
            options,
            desktopIpcDeliveryThread,
            desktopIpcDeliveryBaseline
          );
        }
        if (options.deliveryMode === "interrupt") {
          return await this.interruptAndStartTurnViaCodexDesktopIpc(
            threadId,
            effectiveText,
            options,
            desktopIpcDeliveryBaseline
          );
        }
        return await this.startTurnViaCodexDesktopIpc(threadId, effectiveText, options, desktopIpcDeliveryBaseline);
      } catch (error) {
        const desktopIpcError = error instanceof Error ? error : new Error(String(error));
        if (codexSourceKindRequiresDesktopIpc(desktopIpcDeliveryThread.sourceKind)) {
          const runningTurnSnapshot = activeDeliverySnapshot;
          if (
            steerDeliveryRequested
            && this.isCodexDesktopIpcNoClientError(desktopIpcError)
            && runningTurnSnapshot !== null
            && Boolean(runningTurnSnapshot.activeTurnId)
          ) {
            try {
              const steered = await this.startTurnViaAppServerSteer(
                threadId,
                activeDeliveryText,
                runningTurnSnapshot,
                { swallowErrors: false }
              );
              if (steered) {
                return steered;
              }
            } catch (steerError) {
              appServerSteerError = steerError instanceof Error ? steerError : new Error(String(steerError));
            }
          }
          if (
            this.shouldFallbackDesktopIpcNoClientToAppServer(
              desktopIpcError,
              desktopIpcDeliveryBaseline,
              desktopIpcDeliveryThread.sourceKind
            )
          ) {
            const needsDesktopRouteRefresh = codexSourceKindRequiresDesktopIpc(desktopIpcDeliveryThread.sourceKind);
            console.warn(
              needsDesktopRouteRefresh
                ? `[bridge] Codex Desktop IPC had no client for idle desktop thread ${threadId}; loading it through app-server and refreshing Codex.app.`
                : `[bridge] Codex Desktop IPC had no client for idle thread ${threadId}; loading the thread and starting via app-server instead.`
            );
            if (needsDesktopRouteRefresh) {
              this.codexDesktopAppServerRefreshThreads.add(threadId);
            }
            let result: JSONValue | undefined;
            try {
              result = await this.startTurnViaAppServerAfterEnsuringThreadLoaded(
                threadId,
                activeDeliveryText,
                options,
                needsDesktopRouteRefresh
                  ? "appServerStartAfterDesktopIpcNoClientWithDesktopRefresh"
                  : "appServerStartAfterDesktopIpcNoClient"
              );
            } catch (error) {
              if (needsDesktopRouteRefresh) {
                this.codexDesktopAppServerRefreshThreads.delete(threadId);
              }
              throw error;
            }
            if (needsDesktopRouteRefresh) {
              void this.refreshCodexDesktopThreadRoute(threadId, "desktop-ipc-no-client");
            }
            return result;
          }
          throw new Error(this.codexDesktopIpcDeliveryFailureMessage(threadId, desktopIpcError));
        }
        console.warn(
          `[bridge] Codex Desktop IPC delivery failed for ${threadId}; falling back to app-server: ${desktopIpcError.message}`
        );
      }
    }

    if (options.deliveryMode === "interrupt") {
      await this.interruptRunningThreadBeforeSend(threadId, effectiveText);
    }

    if (activeDeliveryNeedsRunningTurnSteer && activeDeliverySnapshot && !activeDeliveryHasRuntimeRelay) {
      try {
        const steered = await this.startTurnViaAppServerSteer(threadId, activeDeliveryText, activeDeliverySnapshot, {
          swallowErrors: false,
        });
        if (steered) {
          return steered;
        }
      } catch (error) {
        appServerSteerError = error instanceof Error ? error : new Error(String(error));
      }
    }

    if (activeDeliveryRequested && activeDeliveryNeedsRunningTurnSteer) {
      const thread = activeDeliveryThread;
      const isCLIThread = thread?.sourceKind?.trim().toLowerCase() === "cli";
      if (isCLIThread && !findMatchingLaunchByThreadID("codex", threadId)) {
        const ensured = await this.ensureManagedShellThread(threadId, {
          launchManagedShell: true,
          preferVisibleLaunch: false,
        });
        threadId = ensured.threadId;
      }
    }

    const hasExactManagedLaunch = Boolean(findMatchingLaunchByThreadID("codex", threadId));
    const preferCLIResumeFallback = await this.shouldPreferCLIResumeFallback(threadId);
    const preferShellRelayFirst = await this.shouldPreferShellRelayFirst(threadId);

    if (preferShellRelayFirst) {
      attemptedShellRelay = true;
      try {
        const shellRelayResult = await this.startTurnViaVerifiedShellRelay(threadId, shellRelayText, options);
        if (shellRelayResult) {
          return shellRelayResult;
        }
      } catch (error) {
        shellRelayError = error instanceof Error ? error : new Error(String(error));
      }

      throw shellRelayError ?? new Error(`shell relay is required for attached Codex CLI thread ${threadId}`);
    }

    if (activeDeliveryNeedsRunningTurnSteer && !activeDeliveryUsesSharedDesktopSurface) {
      if (!attemptedShellRelay) {
        attemptedShellRelay = true;
        try {
          const shellRelayResult = await this.startTurnViaVerifiedShellRelay(threadId, shellRelayText, options);
          if (shellRelayResult) {
            return shellRelayResult;
          }
        } catch (error) {
          shellRelayError = error instanceof Error ? error : new Error(String(error));
        }
      }

      throw new Error(this.activeDeliveryFailureMessage(threadId, options.deliveryMode, appServerSteerError, shellRelayError));
    }

    if (await this.shouldStartViaAppServer(threadId)) {
      try {
        return await this.startTurnViaAppServer(threadId, effectiveText, options);
      } catch (error) {
        appServerStartError = error instanceof Error ? error : new Error(String(error));
        if (await this.tryResumeAppServerThreadForDelivery(threadId, appServerStartError)) {
          return await this.startTurnViaAppServer(threadId, effectiveText, options);
        }
        if (
          (preferCLIResumeFallback || hasExactManagedLaunch)
          && await this.shouldResumeTurnViaCLI(threadId, appServerStartError)
        ) {
          // Exact thread-stamped helm sessions must materialize a real shared-thread turn.
          // If app-server can no longer resolve that thread, resume the real thread natively
          // instead of falling through to prompt-level shell injection.
          return await this.startTurnViaCLIResume(threadId, effectiveText, options);
        }
        if (
          activeDeliveryRequested
          && !hasImageAttachments
          && this.shouldRetryAppServerStartAfterThreadLoadError(appServerStartError)
        ) {
          return await this.startTurnViaAppServerAfterEnsuringThreadLoaded(
            threadId,
            activeDeliveryText,
            options,
            "appServerStartAfterThreadLoadRetry"
          );
        }
      }
    }

    if (!preferCLIResumeFallback && !attemptedShellRelay && !hasImageAttachments) {
      try {
        const shellRelayResult = await this.startTurnViaVerifiedShellRelay(threadId, effectiveText, options);
        if (shellRelayResult) {
          return shellRelayResult;
        }
      } catch (error) {
        shellRelayError = error instanceof Error ? error : new Error(String(error));
      }
    }

    try {
      return await this.startTurnViaAppServer(threadId, effectiveText, options);
    } catch (error) {
      if (await this.tryResumeAppServerThreadForDelivery(threadId, error)) {
        return await this.startTurnViaAppServer(threadId, effectiveText, options);
      }
      if (await this.shouldResumeTurnViaCLI(threadId, error)) {
        return await this.startTurnViaCLIResume(threadId, effectiveText, options);
      }
      if (
        activeDeliveryRequested
        && !hasImageAttachments
        && this.shouldRetryAppServerStartAfterThreadLoadError(error)
      ) {
        return await this.startTurnViaAppServerAfterEnsuringThreadLoaded(
          threadId,
          activeDeliveryText,
          options,
          "appServerStartAfterThreadLoadRetry"
        );
      }
      if (appServerStartError && shellRelayError) {
        throw new Error(`${appServerStartError.message}; shell relay also failed: ${shellRelayError.message}; app-server turn delivery also failed: ${error instanceof Error ? error.message : String(error)}`);
      }
      if (appServerStartError) {
        throw new Error(`${appServerStartError.message}; app-server turn delivery also failed: ${error instanceof Error ? error.message : String(error)}`);
      }
      if (shellRelayError) {
        throw new Error(`${shellRelayError.message}; app-server turn delivery also failed: ${error instanceof Error ? error.message : String(error)}`);
      }
      throw error;
    }
  }

  private turnInput(text: string, options: StartTurnOptions): CodexUserInput[] {
    const input: CodexUserInput[] = [];
    const trimmed = text.trim();
    if (trimmed) {
      input.push({
        type: "text",
        text: trimmed,
        text_elements: [],
      });
    }

    for (const attachment of options.imageAttachments ?? []) {
      input.push({
        type: "localImage",
        path: attachment.path,
      });
    }

    return input;
  }

  private async startTurnViaAppServer(
    threadId: string,
    text: string,
    options: StartTurnOptions = {},
    mode = "appServerStart"
  ): Promise<JSONValue | undefined> {
    const result = await this.request("turn/start", {
      threadId,
      input: this.turnInput(text, options),
    });
    if (!isRecord(result)) {
      return result;
    }
    return {
      ...result,
      mode: stringValue(result.mode) ?? mode,
      threadId: stringValue(result.threadId) ?? threadId,
    };
  }

  private async startTurnViaAppServerAfterEnsuringThreadLoaded(
    threadId: string,
    text: string,
    options: StartTurnOptions = {},
    mode = "appServerStartAfterThreadLoad"
  ): Promise<JSONValue | undefined> {
    await this.ensureAppServerThreadLoadedForDelivery(threadId, { forceResume: true });
    return await this.startTurnViaAppServer(threadId, text, options, mode);
  }

  private async ensureAppServerThreadLoadedForDelivery(
    threadId: string,
    options: { forceResume?: boolean } = {}
  ): Promise<void> {
    if (!options.forceResume) {
      try {
        const loaded = await this.listLoadedThreads();
        if (loaded.has(threadId)) {
          return;
        }
      } catch (error) {
        console.warn(
          `[bridge] Codex thread/loaded/list failed before delivery retry for ${threadId}: ${errorMessage(error)}`
        );
      }
    }

    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      return;
    }

    const rolloutPath = await resolveCodexThreadRolloutPath(threadId);
    if (!rolloutPath) {
      return;
    }

    try {
      await this.request("thread/resume", {
        threadId,
        path: rolloutPath,
        cwd: thread.cwd || null,
        persistExtendedHistory: true,
        includeTurns: false,
      });
    } catch (error) {
      const message = errorMessage(error).toLowerCase();
      if (
        message.includes("cannot resume running thread")
        || message.includes("retry thread/resume after the thread is closed")
        || message.includes("already loaded")
      ) {
        return;
      }
      throw error;
    }
  }

  private shouldFallbackDesktopIpcNoClientToAppServer(
    error: Error,
    baseline: ThreadDeliverySnapshot | null,
    sourceKind: string | null | undefined
  ): boolean {
    if (!this.isCodexDesktopIpcNoClientError(error) || baseline?.threadStatus === "running") {
      return false;
    }

    if (!codexSourceKindRequiresDesktopIpc(sourceKind)) {
      return true;
    }

    return this.canRefreshCodexDesktopThreadRoute();
  }

  private shouldRetryAppServerStartAfterThreadLoadError(error: unknown): boolean {
    const message = errorMessage(error).toLowerCase();
    return message.includes("thread not loaded")
      || message.includes("thread not found")
      || message.includes("is not materialized yet");
  }

  private isCodexDesktopIpcNoClientError(error: Error): boolean {
    if (error instanceof CodexDesktopIpcRequestError && error.code === "no-client-found") {
      return true;
    }
    return error.message.toLowerCase().includes("no-client-found");
  }

  private canRefreshCodexDesktopThreadRoute(): boolean {
    if (process.platform !== "darwin") {
      return false;
    }

    const value = process.env.HELM_CODEX_DESKTOP_REFRESH?.trim().toLowerCase();
    return value !== "0" && value !== "false" && value !== "no" && value !== "off";
  }

  private handleCodexDesktopAppServerRefreshEvent(event: ConversationEvent): void {
    const method = event.method.trim().toLowerCase();
    if (method !== "turn/completed" && method !== "turn/failed" && method !== "turn/error") {
      return;
    }

    const threadId = threadIdFromPayload(event.params);
    if (!threadId || !this.codexDesktopAppServerRefreshThreads.has(threadId)) {
      return;
    }

    void this.refreshCodexDesktopThreadRoute(threadId, method).finally(() => {
      this.codexDesktopAppServerRefreshThreads.delete(threadId);
    });
  }

  private async refreshCodexDesktopThreadRoute(threadId: string, reason = "refresh"): Promise<boolean> {
    if (!this.canRefreshCodexDesktopThreadRoute()) {
      return false;
    }

    const targetUrl = `codex://threads/${encodeURIComponent(threadId)}`;
    try {
      await this.openCodexDesktopUrl(CODEX_DESKTOP_REFRESH_BOUNCE_URL);
      await sleep(CODEX_DESKTOP_REFRESH_AFTER_BOUNCE_MS);
      await this.openCodexDesktopUrl(targetUrl);
      await sleep(CODEX_DESKTOP_REFRESH_AFTER_TARGET_MS);
      console.log(`[bridge] Refreshed Codex.app thread route ${threadId} after ${reason}`);
      return true;
    } catch (error) {
      console.warn(
        `[bridge] Failed to refresh Codex.app thread route ${threadId}: ${error instanceof Error ? error.message : String(error)}`
      );
      return false;
    }
  }

  private async openCodexDesktopUrl(url: string): Promise<void> {
    const bundleId = process.env.HELM_CODEX_BUNDLE_ID?.trim() || CODEX_DESKTOP_REFRESH_BUNDLE_ID;
    const appPath = process.env.HELM_CODEX_APP_PATH?.trim() || CODEX_DESKTOP_REFRESH_APP_PATH;
    try {
      await execFileAsync("/usr/bin/open", ["-b", bundleId, url], { timeout: 5_000 });
    } catch {
      await execFileAsync("/usr/bin/open", ["-a", appPath, url], { timeout: 5_000 });
    }
  }

  private async startTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: StartTurnOptions,
    baseline: ThreadDeliverySnapshot | null = null
  ): Promise<JSONValue | undefined> {
    if (!isCodexDesktopIpcAvailable()) {
      throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
    }

    const client = new CodexDesktopIpcClient();
    try {
      const result = await client.startTurn(threadId, this.turnInput(text, options));
      await this.requireCodexDesktopIpcDelivery(threadId, text, baseline, "start-turn");
      return this.codexDesktopIpcResult(result, "codexDesktopIpcStart", threadId);
    } finally {
      client.dispose();
    }
  }

  private async interruptAndStartTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: StartTurnOptions,
    baseline: ThreadDeliverySnapshot | null = null
  ): Promise<JSONValue | undefined> {
    if (!isCodexDesktopIpcAvailable()) {
      throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
    }

    const client = new CodexDesktopIpcClient();
    try {
      const shouldInterrupt = baseline?.threadStatus === "running";
      if (shouldInterrupt) {
        try {
          await client.interruptTurn(threadId);
        } catch (error) {
          const interruptError = error instanceof Error ? error : new Error(String(error));
          if (!this.shouldStartTurnAfterCodexDesktopInterruptError(interruptError)) {
            throw interruptError;
          }

          console.warn(
            `[bridge] Codex Desktop IPC interrupt for ${threadId} was unavailable (${interruptError.message}); starting the turn without a pre-interrupt.`
          );
        }
      }

      const result = await client.startTurn(threadId, this.turnInput(text, options));
      await this.requireCodexDesktopIpcDelivery(
        threadId,
        text,
        baseline,
        shouldInterrupt ? "interrupt-start" : "start-after-idle-interrupt-request"
      );
      const mode = shouldInterrupt
        ? "codexDesktopIpcInterruptStart"
        : "codexDesktopIpcStartAfterIdleInterruptRequest";
      return this.codexDesktopIpcResult(result, mode, threadId);
    } finally {
      client.dispose();
    }
  }

  private shouldStartTurnAfterCodexDesktopInterruptError(error: Error): boolean {
    if (error instanceof CodexDesktopIpcRequestError && error.code === "no-client-found") {
      return true;
    }

    const normalized = error.message.toLowerCase();
    return normalized.includes("no-client-found")
      || normalized.includes("steerturninactiveerror")
      || normalized.includes("active turn already ended")
      || normalized.includes("is not being streamed");
  }

  private async enqueueTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: StartTurnOptions,
    thread: ThreadSummary
  ): Promise<JSONValue | undefined> {
    const enqueue = async (): Promise<JSONValue | undefined> => {
      if (!isCodexDesktopIpcAvailable()) {
        throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
      }

      const message = this.codexDesktopQueuedFollowUp(thread, text, options);
      const state = await this.codexDesktopQueuedFollowUpsStateWithAppendedMessage(threadId, message);
      await this.writeCodexDesktopQueuedFollowUpsState(state);
      const client = new CodexDesktopIpcClient();
      try {
        await client.broadcastQueuedFollowUpsChanged(threadId, state[threadId] ?? []);
        return this.codexDesktopIpcResult(
          { ok: true },
          "codexDesktopIpcQueuedFollowUpBroadcast",
          threadId
        );
      } finally {
        client.dispose();
      }
    };

    const result = this.codexDesktopQueueMutation.then(enqueue, enqueue);
    this.codexDesktopQueueMutation = result.catch(() => undefined);
    return await result;
  }

  private async codexDesktopQueuedFollowUpsStateWithAppendedMessage(
    threadId: string,
    message: CodexDesktopQueuedFollowUp
  ): Promise<CodexDesktopQueuedFollowUpsState> {
    const state = await this.readCodexDesktopQueuedFollowUpsState();
    const currentMessages = state[threadId] ?? [];
    return {
      ...state,
      [threadId]: this.codexDesktopQueuedFollowUpsWithAppendedMessage(currentMessages, message),
    };
  }

  private codexDesktopQueuedFollowUpsWithAppendedMessage(
    currentMessages: CodexDesktopQueuedFollowUp[],
    message: CodexDesktopQueuedFollowUp
  ): CodexDesktopQueuedFollowUp[] {
    if (currentMessages.some((currentMessage) => currentMessage.id === message.id)) {
      return currentMessages;
    }
    const messageKey = this.codexDesktopQueuedFollowUpDeduplicationKey(message);
    if (
      currentMessages.some((currentMessage) =>
        Math.abs(message.createdAt - currentMessage.createdAt) <= CODEX_DESKTOP_DUPLICATE_QUEUE_WINDOW_MS
        && this.codexDesktopQueuedFollowUpDeduplicationKey(currentMessage) === messageKey
      )
    ) {
      return currentMessages;
    }
    return [...currentMessages, message];
  }

  private codexDesktopQueuedFollowUpDeduplicationKey(message: CodexDesktopQueuedFollowUp): string {
    return JSON.stringify({
      text: message.text.trim(),
      prompt: stringValue(message.context.prompt)?.trim() ?? "",
      cwd: message.cwd ?? "",
      imageAttachments: message.context.imageAttachments,
      fileAttachments: message.context.fileAttachments,
    });
  }

  private async readCodexDesktopQueuedFollowUpsState(): Promise<CodexDesktopQueuedFollowUpsState> {
    try {
      const raw = await readFile(codexGlobalStatePath(), "utf8");
      const parsed = JSON.parse(raw) as unknown;
      const queuedFollowUps = isRecord(parsed) ? parsed["queued-follow-ups"] : null;
      return this.normalizeCodexDesktopQueuedFollowUpsState(queuedFollowUps);
    } catch (error) {
      if (isRecord(error) && error.code === "ENOENT") {
        return {};
      }
      console.warn(
        `[bridge] Failed to read Codex queued follow-up state; queueing against an empty state: ${error instanceof Error ? error.message : String(error)}`
      );
      return {};
    }
  }

  private async readCodexDesktopActiveWorkspaceRoots(): Promise<string[]> {
    try {
      const raw = await readFile(codexGlobalStatePath(), "utf8");
      const parsed = JSON.parse(raw) as unknown;
      if (!isRecord(parsed)) {
        return [];
      }

      return Array.from(new Set(
        stringArrayValue(parsed["active-workspace-roots"])
          .map((entry) => normalizeWorkspaceRoot(entry))
      ));
    } catch (error) {
      if (isRecord(error) && error.code === "ENOENT") {
        return [];
      }
      throw error;
    }
  }

  private async writeCodexDesktopQueuedFollowUpsState(state: CodexDesktopQueuedFollowUpsState): Promise<void> {
    let globalState: Record<string, unknown> = {};
    try {
      const raw = await readFile(codexGlobalStatePath(), "utf8");
      const parsed = JSON.parse(raw) as unknown;
      if (isRecord(parsed)) {
        globalState = { ...parsed };
      }
    } catch (error) {
      if (!isRecord(error) || error.code !== "ENOENT") {
        console.warn(
          `[bridge] Failed to preserve Codex global state while queueing; rewriting queued follow-ups only: ${error instanceof Error ? error.message : String(error)}`
        );
      }
    }

    globalState["queued-follow-ups"] = state;
    await writeFile(codexGlobalStatePath(), JSON.stringify(globalState), "utf8");
  }

  private normalizeCodexDesktopQueuedFollowUpsState(value: unknown): CodexDesktopQueuedFollowUpsState {
    if (!isRecord(value)) {
      return {};
    }

    const state: CodexDesktopQueuedFollowUpsState = {};
    for (const [threadId, messages] of Object.entries(value)) {
      if (!Array.isArray(messages)) {
        continue;
      }

      const normalizedMessages = messages.filter((message): message is CodexDesktopQueuedFollowUp => {
        return (
          isRecord(message) &&
          typeof message.id === "string" &&
          typeof message.text === "string" &&
          isRecord(message.context)
        );
      });
      if (normalizedMessages.length > 0) {
        state[threadId] = normalizedMessages;
      }
    }
    return state;
  }

  private async steerTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: StartTurnOptions,
    thread: ThreadSummary,
    baseline: ThreadDeliverySnapshot | null = null
  ): Promise<JSONValue | undefined> {
    if (!isCodexDesktopIpcAvailable()) {
      throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
    }

    const input = this.turnInput(text, options);
    const restoreMessage = this.codexDesktopQueuedFollowUp(thread, text, options);
    const client = new CodexDesktopIpcClient();
    try {
      try {
        const result = await client.steerTurn(threadId, input, restoreMessage);
        const delivered = await this.confirmCodexDesktopIpcDelivery(
          threadId,
          text,
          baseline,
          "steer-turn"
        );
        if (!delivered) {
          if (baseline?.threadStatus === "running") {
            throw new Error(`Codex Desktop IPC steer-turn was accepted but did not materialize on ${threadId}`);
          }

          console.warn(
            `[bridge] Codex Desktop IPC steer-turn for ${threadId} was not confirmed; trying start-turn fallback.`
          );
          const startResult = await client.startTurn(threadId, input);
          await this.requireCodexDesktopIpcDelivery(threadId, text, baseline, "start-after-unconfirmed-steer");
          return this.codexDesktopIpcResult(
            startResult,
            "codexDesktopIpcStartAfterUnconfirmedSteer",
            threadId
          );
        }
        return {
          ...(isRecord(result) ? result : {}),
          ok: true,
          mode: "codexDesktopIpcSteerQueued",
          threadId,
        };
      } catch (error) {
        const steerError = error instanceof Error ? error : new Error(String(error));
        if (!this.shouldStartTurnAfterCodexDesktopSteerError(steerError)) {
          throw steerError;
        }

        await client.startTurn(threadId, input);
        await this.requireCodexDesktopIpcDelivery(threadId, text, baseline, "start-after-inactive-steer");
        return {
          ok: true,
          mode: "codexDesktopIpcStartAfterInactiveSteer",
          threadId,
        };
      }
    } finally {
      client.dispose();
    }
  }

  private codexDesktopQueuedFollowUp(
    thread: ThreadSummary,
    text: string,
    options: StartTurnOptions
  ): CodexDesktopQueuedFollowUp {
    const prompt = this.codexDesktopQueuedFollowUpPrompt(text, options);
    const cwd = thread.cwd.trim() || null;
    const workspaceRoot = cwd ?? "/";
    return {
      id: randomUUID(),
      text: prompt,
      context: {
        prompt,
        addedFiles: [],
        fileAttachments: [],
        commentAttachments: [],
        ideContext: null,
        imageAttachments: [],
        workspaceRoots: [workspaceRoot],
        collaborationMode: null,
      },
      cwd,
      createdAt: Date.now(),
    };
  }

  private codexDesktopQueuedFollowUpPrompt(text: string, options: StartTurnOptions): string {
    const trimmed = text.trim();
    if (trimmed) {
      return trimmed;
    }
    const imageAttachments = options.imageAttachments ?? [];
    if (imageAttachments.length > 0) {
      return this.defaultImagePrompt(imageAttachments);
    }
    return "Please continue.";
  }

  private shouldStartTurnAfterCodexDesktopSteerError(error: Error): boolean {
    const normalized = error.message.toLowerCase();
    return normalized.includes("steerturninactiveerror")
      || normalized.includes("active turn already ended")
      || normalized.includes("is not being streamed");
  }

  private async confirmCodexDesktopIpcDelivery(
    threadId: string,
    text: string,
    baseline: ThreadDeliverySnapshot | null,
    operation: string
  ): Promise<boolean> {
    if (!baseline) {
      console.warn(
        `[bridge] Codex Desktop IPC ${operation} for ${threadId} returned without a readable baseline; refusing to report unverified delivery.`
      );
      return false;
    }

    const delivered = await this.waitForThreadDelivery(threadId, text, baseline);
    if (delivered) {
      return true;
    }

    console.warn(
      `[bridge] Codex Desktop IPC ${operation} for ${threadId} returned but no matching thread update was observed.`
    );
    return false;
  }

  private async requireCodexDesktopIpcDelivery(
    threadId: string,
    text: string,
    baseline: ThreadDeliverySnapshot | null,
    operation: string
  ): Promise<void> {
    const delivered = await this.confirmCodexDesktopIpcDelivery(threadId, text, baseline, operation);
    if (!delivered) {
      throw new Error(`Codex Desktop IPC ${operation} did not materialize on ${threadId}`);
    }
  }

  private codexDesktopIpcResult(
    result: JSONValue | undefined,
    mode: string,
    threadId: string
  ): JSONValue {
    const record = isRecord(result) && !Array.isArray(result) ? result : {};
    return {
      ...record,
      ok: record.ok ?? true,
      mode: typeof record.mode === "string" ? record.mode : mode,
      threadId: typeof record.threadId === "string" ? record.threadId : threadId,
    } as JSONValue;
  }

  private textWithFileAttachments(text: string, fileAttachments: StartTurnFileAttachment[]): string {
    const trimmed = text.trim();
    if (fileAttachments.length === 0) {
      return trimmed;
    }

    const attachmentLines = fileAttachments.map((attachment, index) => {
      const filename = attachment.filename?.trim() || `file-${index + 1}`;
      return `- ${filename}: ${attachment.path}`;
    });
    const attachmentBlock = [
      "Attached iPhone files were copied to this Mac. Use these local paths when you need to inspect them:",
      ...attachmentLines,
    ].join("\n");

    if (!trimmed) {
      return `Please inspect the attached iPhone file${fileAttachments.length === 1 ? "" : "s"}.\n\n${attachmentBlock}`;
    }

    return `${trimmed}\n\n${attachmentBlock}`;
  }

  private textWithImageAttachments(text: string, imageAttachments: StartTurnImageAttachment[]): string {
    const trimmed = text.trim();
    if (imageAttachments.length === 0) {
      return trimmed;
    }

    const attachmentLines = imageAttachments.map((attachment, index) => {
      const filename = attachment.filename?.trim() || `image-${index + 1}`;
      return `- ${filename}: ${attachment.path}`;
    });
    const attachmentBlock = [
      "Attached iPhone images were copied to this Mac. Use these local paths when you need to inspect them:",
      ...attachmentLines,
    ].join("\n");

    if (!trimmed) {
      return `Please inspect the attached iPhone image${imageAttachments.length === 1 ? "" : "s"}.\n\n${attachmentBlock}`;
    }

    return `${trimmed}\n\n${attachmentBlock}`;
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    let shellRelayError: Error | null = null;

    const desktopIpcDeliveryThread = await this.loadThreadDeliverySummary(threadId);
    if (
      desktopIpcDeliveryThread
      && codexSourceKindUsesSharedDesktopSurface(desktopIpcDeliveryThread.sourceKind)
    ) {
      try {
        return await this.interruptTurnViaCodexDesktopIpc(threadId);
      } catch (error) {
        const desktopIpcError = error instanceof Error ? error : new Error(String(error));
        if (codexSourceKindRequiresDesktopIpc(desktopIpcDeliveryThread.sourceKind)) {
          throw new Error(this.codexDesktopIpcDeliveryFailureMessage(threadId, desktopIpcError));
        }
        console.warn(
          `[bridge] Codex Desktop IPC interrupt failed for ${threadId}; falling back to app-server: ${desktopIpcError.message}`
        );
      }
    }

    try {
      const shellInterruptResult = await this.interruptTurnViaShellRelay(threadId);
      if (shellInterruptResult) {
        return shellInterruptResult;
      }
    } catch (error) {
      shellRelayError = error instanceof Error ? error : new Error(String(error));
    }

    try {
      return await this.request("turn/interrupt", {
        threadId,
      });
    } catch (error) {
      if (shellRelayError) {
        throw new Error(`${shellRelayError.message}; app-server interrupt also failed: ${error instanceof Error ? error.message : String(error)}`);
      }
      throw error;
    }
  }

  async setModelAndReasoning(
    threadId: string,
    model: string,
    reasoningEffort: string | null = null
  ): Promise<JSONValue | undefined> {
    const trimmedModel = model.trim();
    if (!trimmedModel) {
      throw new Error("Missing model");
    }

    const thread = await this.loadThreadDeliverySummary(threadId);
    if (!thread) {
      throw new Error(`thread not found: ${threadId}`);
    }
    if (!codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      throw new Error("Direct model and reasoning updates require a shared Codex app session.");
    }

    return await this.setModelAndReasoningViaCodexDesktopIpc(
      threadId,
      trimmedModel,
      reasoningEffort?.trim() || null
    );
  }

  private async setModelAndReasoningViaCodexDesktopIpc(
    threadId: string,
    model: string,
    reasoningEffort: string | null
  ): Promise<JSONValue | undefined> {
    if (!isCodexDesktopIpcAvailable()) {
      throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
    }

    const client = new CodexDesktopIpcClient();
    try {
      return await client.setModelAndReasoning(threadId, model, reasoningEffort);
    } finally {
      client.dispose();
    }
  }

  private async interruptTurnViaCodexDesktopIpc(threadId: string): Promise<JSONValue | undefined> {
    if (!isCodexDesktopIpcAvailable()) {
      throw new Error(`Codex Desktop IPC socket is not available at ${codexDesktopIpcSocketPath()}`);
    }

    const client = new CodexDesktopIpcClient();
    try {
      return await client.interruptTurn(threadId);
    } finally {
      client.dispose();
    }
  }

  async sendInput(threadId: string, input: string): Promise<JSONValue | undefined> {
    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      throw new Error(`thread not found: ${threadId}`);
    }

    const launch = findMatchingLaunchByThreadID("codex", threadId);
    if (!isRuntimeRelayAvailable(launch)) {
      throw new Error(`helm shell relay is not available for Codex thread ${threadId}`);
    }

    await sendInputViaRuntimeRelay(launch, input);
    return {
      ok: true,
      mode: "shellRelayInput",
      threadId,
    };
  }

  async renameThread(threadId: string, name: string): Promise<JSONValue | undefined> {
    return await this.request("thread/name/set", {
      threadId,
      name,
    });
  }

  respond(id: JSONRPCId, result: JSONValue): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Codex app-server socket is not connected");
    }

    const response: JSONRPCResponse = {
      id,
      result,
    };
    this.socket.send(JSON.stringify(response));
  }

  private async loadThreadSummary(threadId: string): Promise<ThreadSummary | null> {
    const discovered = await discoverCodexThread(threadId);
    if (discovered) {
      return discovered;
    }

    const listed = (await this.listThreadsFromAppServer()).find((thread) => thread.id === threadId) ?? null;
    if (listed) {
      return listed;
    }

    const result = await this.readThread(threadId, { includeTurns: false });
    if (!isRecord(result) || !isRecord(result.thread) || typeof result.thread.id !== "string") {
      return null;
    }

    const updatedAt = normalizeUpdatedAt(
      typeof result.thread.updatedAt === "number" ? result.thread.updatedAt : Date.now()
    );
    const exactLaunch = findMatchingLaunchByThreadID("codex", threadId);
    const name = typeof result.thread.name === "string" && result.thread.name.length > 0
      ? result.thread.name
      : null;

    return {
      id: result.thread.id,
      name,
      preview: normalizedThreadSummaryPreview(
        null,
        name,
        typeof result.thread.status === "string" && result.thread.status.length > 0
          ? result.thread.status
          : inferredStatusForUpdatedAt(updatedAt, {
            preferRecentIdle: true,
          }),
        name ?? "Codex CLI session"
      ),
      cwd: typeof result.thread.cwd === "string" ? result.thread.cwd : "",
      projectName: isRecord(result.thread)
        ? projectNameValue(result.thread) ?? codexProjectNameForPath(String(result.thread.workspacePath ?? result.thread.cwd ?? ""))
        : null,
      status:
        typeof result.thread.status === "string" && result.thread.status.length > 0
          ? result.thread.status
          : inferredStatusForUpdatedAt(updatedAt, {
            preferRecentIdle: true,
          }),
      updatedAt,
      sourceKind: null,
      launchSource: exactLaunch ? HELM_RUNTIME_LAUNCH_SOURCE : null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    };
  }

  private async loadThreadDeliverySummary(threadId: string): Promise<ThreadSummary | null> {
    const discovered = await discoverCodexThread(threadId);

    try {
      const listed = (await this.listThreadsFromAppServer()).find((thread) => thread.id === threadId) ?? null;
      if (listed) {
        return this.mergeThreadSummary(listed, discovered);
      }
    } catch (error) {
      if (!discovered) {
        console.warn(
          `[bridge] Codex thread/list failed while resolving delivery for ${threadId}: ${errorMessage(error)}`
        );
      }
    }

    if (discovered) {
      return discovered;
    }

    try {
      return await this.loadThreadSummary(threadId);
    } catch (error) {
      console.warn(
        `[bridge] Codex thread summary unavailable while resolving delivery for ${threadId}: ${errorMessage(error)}`
      );
      return null;
    }
  }

  private async launchManagedShellResume(
    threadId: string,
    cwd: string,
    options: {
      visibleTerminal?: boolean;
      extraArgs?: string[];
    } = {}
  ): Promise<boolean> {
    const existingLaunch = findMatchingLaunchByThreadID("codex", threadId);
    if (isRuntimeRelayAvailable(existingLaunch)) {
      return false;
    }

    const visibleTerminal = options.visibleTerminal ?? false;
    const wrapperPath = await resolveHelmRuntimeWrapperPath("codex");
    const resumeArgs = options.extraArgs ?? ["-C", cwd, "resume", threadId];
    if (visibleTerminal) {
      try {
        await launchManagedShellResumeInTerminal(wrapperPath, cwd, resumeArgs);
      } catch (error) {
        console.warn(
          `[bridge] Terminal launch failed for managed thread ${threadId}; falling back to detached launch: ${error instanceof Error ? error.message : String(error)}`
        );
        await launchManagedShellResumeDetached(cwd, resumeArgs);
      }
    } else {
      await launchManagedShellResumeDetached(cwd, resumeArgs);
    }

    await this.waitForManagedShellLaunch(threadId);
    return true;
  }

  private async listLoadedThreads(): Promise<Set<string>> {
    const loaded = new Set<string>();
    let cursor: string | null = null;

    while (true) {
      const params: { [key: string]: JSONValue } = {
        limit: 200,
      };
      if (cursor) {
        params.cursor = cursor;
      }
      const result = await this.request("thread/loaded/list", params);
      const root = (result ?? {}) as {
        data?: unknown[];
        nextCursor?: string | null;
      };

      const data = Array.isArray(root.data) ? root.data : [];
      for (const entry of data) {
        if (typeof entry === "string" && entry.length > 0) {
          loaded.add(entry);
          continue;
        }

        if (!isRecord(entry)) {
          continue;
        }

        const threadId =
          stringValue(entry.threadId)
          ?? stringValue(entry.id)
          ?? stringValue(entry.conversationId);
        if (threadId) {
          loaded.add(threadId);
        }
      }

      cursor = typeof root.nextCursor === "string" && root.nextCursor.length > 0
        ? root.nextCursor
        : null;
      if (!cursor) {
        return loaded;
      }
    }
  }

  private async notifyHistoricalThreadManagedTakeover(threadId: string): Promise<void> {
    try {
      await notifyHistoricalThreadManagedTakeover(threadId);
    } catch (error) {
      console.warn(
        `[bridge] Failed TTY takeover notice for Codex thread ${threadId}: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  private async notifyHistoricalThreadReplacement(
    oldThreadId: string,
    newThreadId: string
  ): Promise<void> {
    let shellCommandDelivered = false;

    try {
      const loadedThreadIDs = await this.listLoadedThreads();
      if (loadedThreadIDs.has(oldThreadId)) {
        await this.request("thread/shellCommand", {
          threadId: oldThreadId,
          command: replacementNoticeShellCommand(newThreadId),
        });
        shellCommandDelivered = true;
      }
    } catch (error) {
      console.warn(
        `[bridge] Failed to notify old Codex thread ${oldThreadId} about replacement ${newThreadId}: ${error instanceof Error ? error.message : String(error)}`
      );
    }

    try {
      if (shellCommandDelivered) {
        await markHistoricalThreadSafeToClose(oldThreadId);
      } else {
        await notifyHistoricalThreadReplacementViaTTY(oldThreadId, newThreadId);
      }
    } catch (error) {
      console.warn(
        `[bridge] Failed TTY fallback for old Codex thread ${oldThreadId} about replacement ${newThreadId}: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  private shouldResumeViaCLI(error: unknown): boolean {
    return error instanceof Error && /thread not found/i.test(error.message);
  }

  private async tryResumeAppServerThreadForDelivery(threadId: string, error: unknown): Promise<boolean> {
    const message = errorMessage(error).toLowerCase();
    if (
      !message.includes("thread not found")
      && !message.includes("failed to locate rollout")
    ) {
      return false;
    }

    const thread = await discoverCodexThread(threadId);
    if (!thread || !codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      return false;
    }
    if (codexSourceKindRequiresDesktopIpc(thread.sourceKind)) {
      return false;
    }

    const rolloutPath = await resolveCodexThreadRolloutPath(threadId);
    await this.request("thread/resume", {
      threadId,
      path: rolloutPath ?? null,
      cwd: thread.cwd || null,
      persistExtendedHistory: true,
      includeTurns: false,
    });
    return true;
  }

  private async shouldResumeTurnViaCLI(threadId: string, error: unknown): Promise<boolean> {
    if (!this.shouldResumeViaCLI(error)) {
      return false;
    }

    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      return false;
    }

    if (codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      console.warn(
        `[bridge] Refusing Codex CLI resume fallback for ${thread.sourceKind ?? "unknown"} thread ${threadId}; keeping delivery on the original desktop thread.`
      );
      return false;
    }

    if (thread.sourceKind?.trim().toLowerCase() === "cli") {
      return true;
    }

    return Boolean(findMatchingLaunchByThreadID("codex", threadId));
  }

  private async shouldStartViaAppServer(threadId: string): Promise<boolean> {
    // Exact thread-stamped helm shells should submit through the shared Codex thread first.
    if (findMatchingLaunchByThreadID("codex", threadId)) {
      return true;
    }

    if (
      listCodexThreadReplacements("codex").some((record) => record.newThreadId === threadId)
    ) {
      return true;
    }

    const thread = await discoverCodexThread(threadId);
    if (
      thread
      && codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)
      && thread.status === "running"
    ) {
      return !codexSourceKindRequiresDesktopIpc(thread.sourceKind);
    }

    try {
      const result = await this.readThread(threadId);
      const root = (result ?? {}) as {
        thread?: {
          turns?: unknown[];
        };
      };
      const turns = Array.isArray(root.thread?.turns) ? root.thread.turns : [];
      return turns.length === 0;
    } catch {
      return false;
    }
  }

  private async shouldPreferCLIResumeFallback(threadId: string): Promise<boolean> {
    if (!findMatchingLaunchByThreadID("codex", threadId)) {
      return false;
    }

    if (listCodexThreadReplacements("codex").some((record) => record.newThreadId === threadId)) {
      return false;
    }

    const thread = await discoverCodexThread(threadId);
    return thread?.sourceKind?.trim().toLowerCase() === "cli";
  }

  private async shouldPreferShellRelayFirst(threadId: string): Promise<boolean> {
    if (!findMatchingLaunchByThreadID("codex", threadId)) {
      return false;
    }

    if (listCodexThreadReplacements("codex").some((record) => record.newThreadId === threadId)) {
      return false;
    }

    const thread = await discoverCodexThread(threadId);
    return thread?.sourceKind?.trim().toLowerCase() === "cli";
  }

  private async startTurnViaVerifiedShellRelay(
    threadId: string,
    text: string,
    options: StartTurnOptions = {}
  ): Promise<JSONValue | undefined> {
    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      return undefined;
    }
    if (codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      console.warn(
        `[bridge] Refusing shell relay delivery for ${thread.sourceKind ?? "unknown"} thread ${threadId}; using Codex Desktop IPC/app-server only.`
      );
      return undefined;
    }

    const launch = findMatchingLaunchByThreadID("codex", threadId);
    if (!isRuntimeRelayAvailable(launch)) {
      return undefined;
    }

    const baselineTail = readRuntimeOutputTail(launch);
    const baselineTailText = baselineTail?.text ?? null;
    const baseline = (await this.readThreadDeliverySnapshot(threadId, text)) ?? {
      hasTurnData: false,
      turnCount: 0,
      matchingUserTextCount: 0,
      updatedAt: normalizeUpdatedAt(baselineTail?.updatedAt ?? Date.now()),
      threadStatus: runtimeTailLooksQueueable(baselineTail) ? "running" : null,
      activeTurnId: null,
    };
    const submitAsQueuedFollowUp =
      options.deliveryMode === "queue" ||
      (!options.deliveryMode &&
        (baseline.threadStatus === "running" || runtimeTailLooksQueueable(baselineTail)));
    const promptDraftToRestore = submitAsQueuedFollowUp
      ? currentPromptDraftFromTerminalTail(baselineTailText)
      : null;

    const relayStartedAt = Date.now();
    await sendTextViaRuntimeRelay(launch, text, {
      clearPromptFirst: true,
      clearPromptMode: submitAsQueuedFollowUp ? "promptOnly" : "dismissAutocomplete",
      inputMode: "bracketedPaste",
      postPasteDelayMs: submitAsQueuedFollowUp ? 250 : undefined,
      pressEnter: !submitAsQueuedFollowUp,
      submitWithTabBeforeEnter: submitAsQueuedFollowUp,
    });

    if (submitAsQueuedFollowUp) {
      let queued = await this.waitForShellRelayQueueAcceptance(
        launch,
        text,
        relayStartedAt,
        baselineTailText,
        SHELL_RELAY_QUEUE_RETRY_DELAY_MS
      );
      if (!queued) {
        await sendTextViaRuntimeRelay(launch, "", {
          pressEnter: false,
          submitWithTabBeforeEnter: true,
        });
        queued = await this.waitForShellRelayQueueAcceptance(
          launch,
          text,
          relayStartedAt,
          baselineTailText,
          SHELL_RELAY_QUEUE_ACCEPT_TIMEOUT_MS
        );
      }
      const materialized = queued
        ? false
        : await this.waitForThreadDelivery(
          threadId,
          text,
          baseline,
          SHELL_RELAY_QUEUE_ACCEPT_TIMEOUT_MS
        );
      if (!queued && !materialized) {
        if (promptDraftToRestore) {
          await this.restoreShellRelayDraft(launch, promptDraftToRestore, { clearPromptFirst: true });
        }
        throw new Error(`shell relay did not confirm Codex queued the follow-up for ${threadId}`);
      }

      if (promptDraftToRestore) {
        await this.restoreShellRelayDraft(launch, promptDraftToRestore, { clearPromptFirst: true });
      } else {
        await this.clearShellRelayPromptAfterQueuedDelivery(launch, threadId);
      }

      return {
        ok: true,
        mode: materialized ? "shellRelayQueuedMaterialized" : "shellRelayQueued",
        threadId,
      };
    }

    const delivered = await this.waitForThreadDelivery(threadId, text, baseline);
    if (!delivered) {
      await this.clearUndeliveredShellRelayDraft(launch, threadId, {
        allowInterrupt: options.deliveryMode === "interrupt",
      });
      throw new Error(`shell relay did not materialize a shared-thread turn for ${threadId}`);
    }

    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  private async clearShellRelayPromptAfterQueuedDelivery(
    launch: RuntimeLaunchRecord,
    threadId: string
  ): Promise<void> {
    try {
      await sendTextViaRuntimeRelay(launch, "", {
        clearPromptFirst: true,
        clearPromptMode: "promptOnly",
        pressEnter: false,
      });
    } catch (error) {
      console.warn(
        `[bridge] Failed to clear Codex prompt after queued relay injection for ${threadId}: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  private async restoreShellRelayDraft(
    launch: RuntimeLaunchRecord,
    text: string,
    options: { clearPromptFirst: boolean }
  ): Promise<void> {
    try {
      await sendTextViaRuntimeRelay(launch, text, {
        clearPromptFirst: options.clearPromptFirst,
        clearPromptMode: "promptOnly",
        inputMode: "bracketedPaste",
        pressEnter: false,
      });
    } catch (error) {
      console.warn(
        `[bridge] Failed to restore Codex prompt draft after queued relay injection: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  private async interruptTurnViaShellRelay(threadId: string): Promise<JSONValue | undefined> {
    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      return undefined;
    }
    if (codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      console.warn(
        `[bridge] Refusing shell relay interrupt for ${thread.sourceKind ?? "unknown"} thread ${threadId}; using Codex Desktop IPC/app-server only.`
      );
      return undefined;
    }

    const launch = findMatchingLaunchByThreadID("codex", threadId);
    if (!isRuntimeRelayAvailable(launch)) {
      return undefined;
    }

    await interruptViaRuntimeRelay(launch);
    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  private async startTurnViaCLIResume(
    threadId: string,
    text: string,
    options: StartTurnOptions = {}
  ): Promise<JSONValue | undefined> {
    const thread = await discoverCodexThread(threadId);
    if (!thread) {
      throw new Error(`thread not found: ${threadId}`);
    }
    if (codexSourceKindUsesSharedDesktopSurface(thread.sourceKind)) {
      throw new Error(`refusing CLI resume fallback for Codex desktop thread ${threadId}`);
    }

    const prompt = text.trim() || this.defaultImagePrompt(options.imageAttachments ?? []);
    const args = ["-C", thread.cwd, "exec", "resume", "--json"];
    for (const attachment of options.imageAttachments ?? []) {
      args.push("--image", attachment.path);
    }
    args.push(threadId, prompt);
    const child = spawn(resolveUnderlyingRuntimeBinary("codex"), args, {
      cwd: thread.cwd,
      detached: true,
      stdio: "ignore",
      env: {
        ...process.env,
        HELM_DISABLE_AUTO_BRIDGE: "1",
      },
    });

    await new Promise<void>((resolve, reject) => {
      child.once("spawn", () => resolve());
      child.once("error", (spawnError) => reject(spawnError));
    });
    child.unref();

    return {
      ok: true,
      mode: "cliResumeFallback",
      threadId,
    };
  }

  private activeDeliveryFailureMessage(
    threadId: string,
    deliveryMode: StartTurnOptions["deliveryMode"],
    appServerSteerError: Error | null,
    shellRelayError: Error | null
  ): string {
    const label = deliveryMode === "steer" ? "steer" : "queued";
    const reasons = [
      appServerSteerError ? `app-server steer failed: ${appServerSteerError.message}` : null,
      shellRelayError ? `shell relay ${label} failed: ${shellRelayError.message}` : null,
    ].filter((reason): reason is string => Boolean(reason));
    const suffix = reasons.length > 0 ? ` (${reasons.join("; ")})` : "";
    return `Codex thread ${threadId} is running; ${label} delivery could not be confirmed, so the message was not sent${suffix}`;
  }

  private codexDesktopIpcDeliveryFailureMessage(threadId: string, error: Error): string {
    return [
      `Codex.app delivery failed for ${threadId}: ${error.message}`,
      "Helm did not fall back to the standalone app-server because Codex.app route refresh is unavailable or the thread is still running.",
      "Keep the thread open in Codex.app and try again.",
    ].join(" ");
  }

  private defaultImagePrompt(imageAttachments: StartTurnImageAttachment[]): string {
    if (imageAttachments.length === 1) {
      return "Please inspect the attached image.";
    }
    return `Please inspect the ${imageAttachments.length} attached images.`;
  }

  private async readThreadDeliverySnapshot(
    threadId: string,
    text: string
  ): Promise<ThreadDeliverySnapshot | null> {
    try {
      const result = await this.readThread(threadId);
      return this.threadDeliverySnapshotFromResult(result, text, true);
    } catch {
      try {
        const result = await this.readThreadMetadata(threadId);
        return this.threadDeliverySnapshotFromResult(result, text, false);
      } catch {
        return null;
      }
    }
  }

  private threadDeliverySnapshotFromResult(
    result: JSONValue | undefined,
    text: string,
    hasTurnData: boolean
  ): ThreadDeliverySnapshot {
    const root = (result ?? {}) as {
      thread?: {
        turns?: unknown[];
        updatedAt?: number;
        status?: string | { type?: unknown };
      };
    };
    const turns = hasTurnData && Array.isArray(root.thread?.turns) ? root.thread.turns : [];
    return {
      hasTurnData,
      turnCount: turns.length,
      matchingUserTextCount: hasTurnData ? countMatchingUserMessages(turns, text) : 0,
      updatedAt: normalizeUpdatedAt(
        typeof root.thread?.updatedAt === "number" ? root.thread.updatedAt : 0
      ),
      threadStatus: normalizeThreadStatus(root.thread?.status),
      activeTurnId: hasTurnData ? activeTurnIdFromTurns(turns) : null,
    };
  }

  private threadDeliverySnapshotFromSummary(thread: ThreadSummary): ThreadDeliverySnapshot {
    return {
      hasTurnData: false,
      turnCount: 0,
      matchingUserTextCount: 0,
      updatedAt: normalizeUpdatedAt(thread.updatedAt),
      threadStatus: normalizeThreadStatus(thread.status),
      activeTurnId: null,
    };
  }

  private async startTurnViaAppServerSteer(
    threadId: string,
    text: string,
    baseline: ThreadDeliverySnapshot,
    options: { swallowErrors?: boolean } = {}
  ): Promise<JSONValue | undefined> {
    if (!baseline.activeTurnId) {
      return undefined;
    }

    try {
      await this.request("turn/steer", {
        threadId,
        input: this.turnInput(text, {}),
        expectedTurnId: baseline.activeTurnId,
      });
      return {
        ok: true,
        mode: "appServerSteerQueued",
        threadId,
      };
    } catch (error) {
      console.warn(
        `[bridge] Codex app-server turn/steer failed for ${threadId}: ${error instanceof Error ? error.message : String(error)}`
      );
      if (await this.tryResumeAppServerThreadForDelivery(threadId, error)) {
        await this.request("turn/steer", {
          threadId,
          input: this.turnInput(text, {}),
          expectedTurnId: baseline.activeTurnId,
        });
        return {
          ok: true,
          mode: "appServerSteerQueued",
          threadId,
        };
      }
      if (options.swallowErrors === false) {
        throw error;
      }
      return undefined;
    }
  }

  private async waitForThreadDelivery(
    threadId: string,
    text: string,
    baseline: ThreadDeliverySnapshot,
    timeoutMs = SHELL_RELAY_DELIVERY_TIMEOUT_MS
  ): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;

    while (Date.now() < deadline) {
      const snapshot = await this.readThreadDeliverySnapshot(threadId, text);
      if (
        snapshot
        && (
          (
            snapshot.hasTurnData
            && baseline.hasTurnData
            && (
              snapshot.turnCount > baseline.turnCount
              || snapshot.matchingUserTextCount > baseline.matchingUserTextCount
            )
          )
          || (
            snapshot.updatedAt > baseline.updatedAt
            && (snapshot.threadStatus === "running" || baseline.threadStatus === "running")
          )
          || (
            baseline.threadStatus !== "running"
            && snapshot.threadStatus === "running"
          )
        )
      ) {
        return true;
      }

      await new Promise((resolve) => setTimeout(resolve, SHELL_RELAY_DELIVERY_POLL_INTERVAL_MS));
    }

    return false;
  }

  private async interruptRunningThreadBeforeSend(threadId: string, text: string): Promise<void> {
    const snapshot = await this.readThreadDeliverySnapshot(threadId, text);
    if (snapshot?.threadStatus !== "running") {
      return;
    }

    await this.interruptTurn(threadId);
    const interrupted = await this.waitForThreadNotRunning(threadId, text, INTERRUPT_BEFORE_SEND_TIMEOUT_MS);
    if (!interrupted) {
      throw new Error(`Codex thread ${threadId} did not stop after interrupt; message was not sent.`);
    }
  }

  private async waitForThreadNotRunning(
    threadId: string,
    text: string,
    timeoutMs: number
  ): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;

    while (Date.now() < deadline) {
      const snapshot = await this.readThreadDeliverySnapshot(threadId, text);
      if (snapshot && snapshot.threadStatus !== "running") {
        return true;
      }

      await new Promise((resolve) => setTimeout(resolve, SHELL_RELAY_DELIVERY_POLL_INTERVAL_MS));
    }

    return false;
  }

  private async waitForShellRelayQueueAcceptance(
    launch: RuntimeLaunchRecord,
    text: string,
    relayStartedAt: number,
    baselineTailText: string | null,
    timeoutMs = SHELL_RELAY_QUEUE_ACCEPT_TIMEOUT_MS
  ): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;

    while (Date.now() < deadline) {
      const tail = readRuntimeOutputTail(launch);
      if (
        tail &&
        tail.updatedAt >= relayStartedAt &&
        tailContainsQueuedFollowUp(terminalTailDelta(baselineTailText, tail.text), text)
      ) {
        return true;
      }

      await new Promise((resolve) => setTimeout(resolve, SHELL_RELAY_QUEUE_ACCEPT_POLL_INTERVAL_MS));
    }

    return false;
  }

  private async clearUndeliveredShellRelayDraft(
    launch: NonNullable<ReturnType<typeof findMatchingLaunchByThreadID>>,
    threadId: string,
    options: { allowInterrupt: boolean }
  ): Promise<void> {
    if (!options.allowInterrupt) {
      console.warn(
        `[bridge] Shell-relay delivery for Codex thread ${threadId} was not verified; leaving desktop turn uninterrupted.`
      );
      return;
    }

    try {
      await interruptViaRuntimeRelay(launch);
    } catch (error) {
      console.warn(
        `[bridge] Failed to clear undelivered shell-relay draft for Codex thread ${threadId}: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  private extractThreadId(result: JSONValue | undefined): string | null {
    if (!isRecord(result)) {
      return null;
    }

    const thread = result.thread;
    if (!isRecord(thread) || typeof thread.id !== "string" || thread.id.length === 0) {
      return null;
    }

    return thread.id;
  }

  private async waitForThreadTurnCount(threadId: string, minimumTurns: number): Promise<void> {
    const deadline = Date.now() + BOOTSTRAP_TIMEOUT_MS;

    while (Date.now() < deadline) {
      try {
        const result = await this.readThread(threadId);
        const root = (result ?? {}) as {
          thread?: {
            turns?: unknown[];
            status?: string | { type?: unknown };
          };
        };
        const turns = Array.isArray(root.thread?.turns) ? root.thread.turns : [];
        const lastTurn = turns.at(-1);
        const lastTurnStatus =
          isRecord(lastTurn) && typeof lastTurn.status === "string" ? lastTurn.status : null;
        const threadStatus =
          typeof root.thread?.status === "string"
            ? root.thread.status
            : isRecord(root.thread?.status) && typeof root.thread.status.type === "string"
              ? root.thread.status.type
              : null;

        if (
          turns.length >= minimumTurns &&
          threadStatus === "idle" &&
          (lastTurnStatus === null || lastTurnStatus === "completed")
        ) {
          return;
        }
      } catch {
        // Thread is not materialized yet.
      }

      await new Promise((resolve) => setTimeout(resolve, BOOTSTRAP_POLL_INTERVAL_MS));
    }

    throw new Error(`Timed out waiting for Codex thread ${threadId} bootstrap turn to settle.`);
  }

  private async waitForDiscoveredThread(threadId: string): Promise<void> {
    const deadline = Date.now() + BOOTSTRAP_TIMEOUT_MS;

    while (Date.now() < deadline) {
      const discovered = await discoverCodexThread(threadId);
      if (discovered) {
        return;
      }

      await new Promise((resolve) => setTimeout(resolve, BOOTSTRAP_POLL_INTERVAL_MS));
    }

    throw new Error(`Timed out waiting for bootstrap thread ${threadId} to reach local discovery.`);
  }

  private async waitForManagedShellLaunch(threadId: string): Promise<void> {
    const deadline = Date.now() + MANAGED_SHELL_LAUNCH_TIMEOUT_MS;

    while (Date.now() < deadline) {
      const launch = findMatchingLaunchByThreadID("codex", threadId);
      if (isRuntimeRelayAvailable(launch)) {
        return;
      }

      await new Promise((resolve) => setTimeout(resolve, BOOTSTRAP_POLL_INTERVAL_MS));
    }

    throw new Error(`Timed out waiting for managed Codex shell launch ${threadId}.`);
  }

  private async resolveUsableHistoricalReplacement(threadId: string): Promise<{ oldThreadId: string; newThreadId: string; replacedAt: number; runtime: string } | null> {
    const resolvedReplacement = resolveCodexThreadReplacement("codex", threadId);
    if (!resolvedReplacement) {
      return null;
    }

    if (!(await this.isUsableHistoricalReplacement(resolvedReplacement.newThreadId))) {
      deleteCodexThreadReplacement("codex", resolvedReplacement.oldThreadId);
      try {
        if (!findMatchingLaunchByThreadID("codex", resolvedReplacement.newThreadId)) {
          await this.archiveThread(resolvedReplacement.newThreadId);
        }
      } catch {
        // Ignore cleanup failure; the important part is to stop canonicalizing to the bad replacement.
      }
      return null;
    }

    return resolvedReplacement;
  }

  private async isUsableHistoricalReplacement(threadId: string): Promise<boolean> {
    try {
      const result = await this.readThread(threadId);
      if (!isRecord(result) || !isRecord(result.thread)) {
        return false;
      }

      const turns = Array.isArray(result.thread.turns) ? result.thread.turns : [];
      const preview = typeof result.thread.preview === "string" ? result.thread.preview.trim() : "";
      const source = typeof result.thread.source === "string"
        ? result.thread.source.trim().toLowerCase()
        : "";

      return !(turns.length === 0 && source === "vscode" && preview === BOOTSTRAP_THREAD_TEXT);
    } catch {
      return false;
    }
  }
}

function codexSourceKindSupportsManagedShellAdoption(sourceKind: string | null | undefined): boolean {
  const normalized = sourceKind?.trim().toLowerCase() ?? "";
  return normalized === "" || normalized === "cli";
}

function codexSourceKindUsesSharedDesktopSurface(sourceKind: string | null | undefined): boolean {
  const normalized = sourceKind?.trim().toLowerCase() ?? "";
  return normalized === "vscode" || normalized === "appserver";
}

function codexSourceKindRequiresDesktopIpc(sourceKind: string | null | undefined): boolean {
  const normalized = sourceKind?.trim().toLowerCase() ?? "";
  return normalized === "vscode";
}

function codexDesktopThreadController(now = Date.now()): ThreadController {
  return {
    clientId: CODEX_DESKTOP_CONTROLLER_ID,
    clientName: CODEX_DESKTOP_CONTROLLER_NAME,
    claimedAt: now,
    lastSeenAt: now,
  };
}

async function scrubBootstrapThreadMetadata(threadId: string): Promise<void> {
  const escapedThreadId = threadId.replace(/'/g, "''");
  await execFileAsync(
    "sqlite3",
    [
      codexStatePath(),
      `update threads
         set title = '',
             first_user_message = '',
             source = 'cli'
       where id = '${escapedThreadId}';`,
    ],
    {
      maxBuffer: 1024 * 1024,
    }
  );
}

async function archiveThreadInStateDatabase(threadId: string): Promise<void> {
  const escapedThreadId = threadId.replace(/'/g, "''");
  await execFileAsync(
    "sqlite3",
    [
      codexStatePath(),
      `update threads
         set archived = 1,
             archived_at = strftime('%s','now')
       where id = '${escapedThreadId}';`,
    ],
    {
      maxBuffer: 1024 * 1024,
    }
  );
}

function codexManagedResumeArgs(
  threadId: string,
  cwd: string,
  input: {
    model?: string;
    reasoningEffort?: string;
    codexFastMode?: boolean;
  } = {}
): string[] {
  const args: string[] = [];

  if (input.model?.trim()) {
    args.push("-m", input.model.trim());
  }
  if (input.reasoningEffort?.trim()) {
    args.push("-c", `model_reasoning_effort="${input.reasoningEffort.trim()}"`);
  }
  if (typeof input.codexFastMode === "boolean") {
    args.push("-c", `service_tier="${input.codexFastMode ? "fast" : "flex"}"`);
  }

  args.push("-C", cwd, "resume", threadId);
  return args;
}

async function launchManagedShellResumeDetached(cwd: string, args: string[]): Promise<void> {
  await launchManagedRuntimeDetached({
    runtime: "codex",
    cwd,
    args,
    env: {
      HELM_SKIP_MANAGED_THREAD_REWRITE: "1",
    },
  });
}

async function launchManagedShellResumeInTerminal(
  wrapperPath: string,
  cwd: string,
  args: string[]
): Promise<void> {
  const terminalTitle = managedTerminalTitle(cwd, "Codex");
  const command = [
    `printf '\\033]0;%s\\007' ${shellQuote(terminalTitle)}`,
    `export HELM_DISABLE_AUTO_BRIDGE=1`,
    `export HELM_SKIP_MANAGED_THREAD_REWRITE=1`,
    `cd ${shellQuote(cwd)}`,
    `exec ${shellQuote(wrapperPath)} ${args.map(shellQuote).join(" ")}`,
  ].join("; ");

  await execFileAsync("osascript", [
    "-e",
    'tell application "Terminal"',
    "-e",
    "activate",
    "-e",
    `set helmTab to do script ${appleScriptString(command)}`,
    "-e",
    "try",
    "-e",
    `set custom title of helmTab to ${appleScriptString(terminalTitle)}`,
    "-e",
    "end try",
    "-e",
    "end tell",
  ], {
    maxBuffer: 1024 * 1024,
  });
}

function managedTerminalTitle(cwd: string, cliName: string): string {
  const displayPath = abbreviatedHomePath(cwd.trim() || process.cwd());
  return sanitizeTerminalTitle(`${displayPath} - ${cliName} - Helm`);
}

function abbreviatedHomePath(value: string): string {
  const home = homedir();
  if (value === home) {
    return "~";
  }
  if (value.startsWith(`${home}${path.sep}`)) {
    return `~${value.slice(home.length)}`;
  }
  return value;
}

function sanitizeTerminalTitle(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F]/g, " ").replace(/\s+/g, " ").trim();
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

function appleScriptString(value: string): string {
  return `"${value
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')}"`;
}

function replacementNoticeShellCommand(newThreadId: string): string {
  return [
    "cat <<'HELM_REPLACED_NOTICE'",
    `[helm] This session was copied into a new helm-managed session (${newThreadId}).`,
    "[helm] Continue in the new Terminal session. It is safe to close this old terminal.",
    "HELM_REPLACED_NOTICE",
  ].join("\n");
}

async function notifyHistoricalThreadReplacementViaTTY(
  oldThreadId: string,
  newThreadId: string
): Promise<void> {
  const tty = await findCodexTTYForThread(oldThreadId, { legacyOnly: true });
  if (!tty) {
    return;
  }

  await markTerminalTabSafeToClose(tty);
  await writeFile(path.join("/dev", tty), replacementNoticeTTYPayload(newThreadId));
}

async function notifyHistoricalThreadManagedTakeover(threadId: string): Promise<void> {
  const tty = await findCodexTTYForThread(threadId, { legacyOnly: true });
  if (!tty) {
    return;
  }

  await markTerminalTabSafeToClose(tty);
  await writeFile(path.join("/dev", tty), managedTakeoverTTYPayload(threadId));
}

async function markHistoricalThreadSafeToClose(oldThreadId: string): Promise<void> {
  const tty = await findCodexTTYForThread(oldThreadId, { legacyOnly: true });
  if (!tty) {
    return;
  }

  await markTerminalTabSafeToClose(tty);
}

async function findCodexTTYForThread(
  threadId: string,
  options: { legacyOnly?: boolean } = {}
): Promise<string | null> {
  const { stdout } = await execFileAsync("ps", ["-axo", "pid=,tty=,command="], {
    maxBuffer: 1024 * 1024,
  });
  const lines = stdout.split("\n");
  let bestMatch: { pid: number; tty: string } | null = null;

  for (const line of lines) {
    const match = line.match(/^\s*(\d+)\s+(\S+)\s+(.*)$/);
    if (!match) {
      continue;
    }

    const [, pidText, tty, command] = match;
    if (!pidText || !tty || !command) {
      continue;
    }

    const pid = Number(pidText);
    if (!Number.isFinite(pid) || tty === "??") {
      continue;
    }
    if (!/\bcodex\b/.test(command) || !command.includes(threadId)) {
      continue;
    }
    if (options.legacyOnly && command.includes("helm_runtime_relay.py")) {
      continue;
    }

    if (!bestMatch || pid > bestMatch.pid) {
      bestMatch = { pid, tty };
    }
  }

  return bestMatch?.tty ?? null;
}

function managedTakeoverTTYPayload(threadId: string): string {
  return [
    `\u001B]0;${terminalReplacementTitle()}\u0007`,
    "\r\n",
    `[helm] This conversation is now open in a new helm-managed terminal for the same session (${threadId}).\r\n`,
    "[helm] Continue there. It is safe to close this old terminal.\r\n",
  ].join("");
}

function replacementNoticeTTYPayload(newThreadId: string): string {
  return [
    `\u001B]0;${terminalReplacementTitle()}\u0007`,
    "\r\n",
    `[helm] This session was copied into a new helm-managed session (${newThreadId}).\r\n`,
    "[helm] Continue in the new Terminal session. It is safe to close this old terminal.\r\n",
  ].join("");
}

function terminalReplacementTitle(): string {
  return "helm copied; safe to close";
}

async function markTerminalTabSafeToClose(tty: string): Promise<void> {
  const ttyPath = path.join("/dev", tty);
  const title = terminalReplacementTitle();
  await execFileAsync("osascript", [
    "-e",
    'tell application "Terminal"',
    "-e",
    "repeat with w in windows",
    "-e",
    "repeat with t in tabs of w",
    "-e",
    "try",
    "-e",
    `if (tty of t as text) is ${appleScriptString(ttyPath)} then`,
    "-e",
    `set custom title of t to ${appleScriptString(title)}`,
    "-e",
    "return",
    "-e",
    "end if",
    "-e",
    "end try",
    "-e",
    "end repeat",
    "-e",
    "end repeat",
    "-e",
    "end tell",
  ], {
    maxBuffer: 1024 * 1024,
  });
}
