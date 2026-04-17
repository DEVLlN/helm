import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

import { AgentBackend, type StartThreadInput } from "./agentBackend.js";
import { HELM_RUNTIME_LAUNCH_SOURCE } from "./helmManagedLaunch.js";
import { interruptViaRuntimeRelay, sendInputViaRuntimeRelay, sendTextViaRuntimeRelay } from "./runtimeRelayClient.js";
import { findMatchingLaunchByPID, isRuntimeRelayAvailable } from "./runtimeLaunchRegistry.js";
import { hasHelmRuntimeWrapper, launchManagedRuntimeDetached } from "./runtimeShellLauncher.js";
import type {
  JSONRPCId,
  JSONValue,
  StartTurnFileAttachment,
  StartTurnOptions,
  ThreadSummary,
} from "./types.js";

type ClaudeSessionRecord = {
  pid?: number;
  sessionId?: string;
  cwd?: string;
  startedAt?: number;
  kind?: string;
  entrypoint?: string;
};

type LiveClaudeSessionRecord = ClaudeSessionRecord & {
  sessionId: string;
  cwd: string;
};

type ClaudeConversationSnapshot = {
  latestUserMessage: string | null;
  latestAssistantMessage: string | null;
};

type ClaudeDesktopSessionRecord = {
  sessionId?: string;
  cliSessionId?: string;
  cwd?: string;
  originCwd?: string;
  createdAt?: number;
  lastActivityAt?: number;
  model?: string;
  effort?: string;
  isArchived?: boolean;
  title?: string;
  permissionMode?: string;
};

type ClaudeDiscoveredThread = {
  threadId: string;
  cwd: string;
  updatedAt: number;
  sourceKind: string;
  liveSession: LiveClaudeSessionRecord | null;
  desktopSession: ClaudeDesktopSessionRecord | null;
};

const CLAUDE_LAUNCH_TIMEOUT_MS = 30_000;
const CLAUDE_POLL_INTERVAL_MS = 250;

function claudeRootPath(): string {
  return path.join(homedir(), ".claude");
}

function claudeSessionsPath(): string {
  return path.join(claudeRootPath(), "sessions");
}

function claudeDesktopSessionsPath(): string {
  return path.join(homedir(), "Library", "Application Support", "Claude", "claude-code-sessions");
}

function truncate(text: string, maxLength: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function projectSlug(cwd: string): string {
  return cwd.replace(/\//g, "-") || "-";
}

function normalizeUpdatedAt(value: number | undefined): number {
  if (!value || !Number.isFinite(value)) {
    return Date.now();
  }
  return value > 1_000_000_000_000 ? value : value * 1000;
}

function statusForUpdatedAt(updatedAt: number, live: boolean): string {
  if (live) {
    return "running";
  }
  const ageMS = Math.max(0, Date.now() - updatedAt);
  if (ageMS < 7 * 24 * 60 * 60 * 1000) {
    return "idle";
  }
  return "unknown";
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

function readClaudeSessionRecords(): ClaudeSessionRecord[] {
  const sessionsPath = claudeSessionsPath();
  if (!existsSync(sessionsPath)) {
    return [];
  }

  const entries = readdirSync(sessionsPath)
    .filter((name) => name.endsWith(".json"))
    .map((name) => path.join(sessionsPath, name));

  const sessions: ClaudeSessionRecord[] = [];
  for (const filePath of entries) {
    try {
      const raw = readFileSync(filePath, "utf8");
      const parsed = JSON.parse(raw) as ClaudeSessionRecord;
      if (parsed.sessionId && parsed.cwd) {
        sessions.push(parsed);
      }
    } catch {
      // Ignore malformed session files and continue discovery.
    }
  }

  return sessions
    .filter((session) => isProcessAlive(session.pid))
    .sort((lhs, rhs) => (rhs.startedAt ?? 0) - (lhs.startedAt ?? 0));
}

function readClaudeDesktopSessionRecords(): ClaudeDesktopSessionRecord[] {
  const sessionsPath = claudeDesktopSessionsPath();
  if (!existsSync(sessionsPath)) {
    return [];
  }

  const files = walkClaudeDesktopSessionFiles(sessionsPath);
  const sessions: ClaudeDesktopSessionRecord[] = [];
  for (const filePath of files) {
    try {
      const raw = readFileSync(filePath, "utf8");
      const parsed = JSON.parse(raw) as ClaudeDesktopSessionRecord;
      if (parsed.cliSessionId && parsed.cwd && parsed.isArchived !== true) {
        sessions.push(parsed);
      }
    } catch {
      // Ignore malformed desktop session files and continue discovery.
    }
  }

  return sessions.sort((lhs, rhs) => (rhs.lastActivityAt ?? rhs.createdAt ?? 0) - (lhs.lastActivityAt ?? lhs.createdAt ?? 0));
}

function safeDirectoryEntries(directoryPath: string) {
  try {
    return readdirSync(directoryPath, { withFileTypes: true });
  } catch {
    return [];
  }
}

function walkClaudeDesktopSessionFiles(root: string): string[] {
  const stack = [root];
  const files: string[] = [];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) {
      continue;
    }

    for (const entry of safeDirectoryEntries(current)) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(entryPath);
        continue;
      }

      if (entry.isFile() && entry.name.startsWith("local_") && entry.name.endsWith(".json")) {
        files.push(entryPath);
      }
    }
  }

  return files;
}

function transcriptPathForSession(sessionId: string, cwd?: string | null): string | null {
  if (cwd) {
    const candidate = path.join(claudeRootPath(), "projects", projectSlug(cwd), `${sessionId}.jsonl`);
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  const projectsPath = path.join(claudeRootPath(), "projects");
  if (!existsSync(projectsPath)) {
    return null;
  }

  const stack = [projectsPath];
  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) {
      continue;
    }

    for (const entry of safeDirectoryEntries(current)) {
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(entryPath);
        continue;
      }

      if (entry.isFile() && entry.name === `${sessionId}.jsonl`) {
        return entryPath;
      }
    }
  }

  return null;
}

function extractText(content: unknown): string | null {
  if (typeof content === "string") {
    return content.trim() || null;
  }

  if (Array.isArray(content)) {
    const text = content
      .map((block) => {
        if (!block || typeof block !== "object") {
          return null;
        }
        const candidate = (block as { text?: unknown }).text;
        return typeof candidate === "string" ? candidate.trim() : null;
      })
      .filter((entry): entry is string => Boolean(entry))
      .join("\n\n")
      .trim();
    return text || null;
  }

  if (content && typeof content === "object") {
    const candidate = (content as { text?: unknown }).text;
    if (typeof candidate === "string") {
      return candidate.trim() || null;
    }
  }

  return null;
}

function readClaudeConversationSnapshot(sessionId: string, cwd?: string | null): ClaudeConversationSnapshot {
  const transcriptPath = transcriptPathForSession(sessionId, cwd);
  if (!transcriptPath || !existsSync(transcriptPath)) {
    return {
      latestUserMessage: null,
      latestAssistantMessage: null,
    };
  }

  try {
    const lines = readFileSync(transcriptPath, "utf8")
      .split(/\r?\n/)
      .filter((line) => line.trim().length > 0)
      .slice(-300);

    let latestUserMessage: string | null = null;
    let latestAssistantMessage: string | null = null;

    for (const line of lines) {
      try {
        const entry = JSON.parse(line) as {
          type?: string;
          message?: { content?: unknown };
        };

        if (entry.type === "user") {
          const message = extractText(entry.message?.content);
          if (message) {
            latestUserMessage = truncate(message, 600);
          }
        } else if (entry.type === "assistant") {
          const message = extractText(entry.message?.content);
          if (message) {
            latestAssistantMessage = truncate(message, 600);
          }
        }
      } catch {
        // Ignore malformed JSONL rows and continue.
      }
    }

    return {
      latestUserMessage,
      latestAssistantMessage,
    };
  } catch {
    return {
      latestUserMessage: null,
      latestAssistantMessage: null,
    };
  }
}

function discoverClaudeThreads(): ClaudeDiscoveredThread[] {
  const liveSessions = readClaudeSessionRecords();
  const desktopSessions = readClaudeDesktopSessionRecords();
  const desktopByCliSessionId = new Map(
    desktopSessions
      .filter((session) => typeof session.cliSessionId === "string" && session.cliSessionId.length > 0)
      .map((session) => [session.cliSessionId!, session] as const)
  );
  const threads = new Map<string, ClaudeDiscoveredThread>();

  for (const liveSession of liveSessions) {
    if (!liveSession.sessionId || !liveSession.cwd) {
      continue;
    }
    const assuredLiveSession = liveSession as LiveClaudeSessionRecord;
    const desktopSession = desktopByCliSessionId.get(liveSession.sessionId) ?? null;
    const updatedAt = normalizeUpdatedAt(
      Math.max(liveSession.startedAt ?? 0, desktopSession?.lastActivityAt ?? 0, desktopSession?.createdAt ?? 0)
    );
    threads.set(liveSession.sessionId, {
      threadId: liveSession.sessionId,
      cwd: desktopSession?.cwd ?? liveSession.cwd,
      updatedAt,
      sourceKind: desktopSession ? "claude-desktop" : liveSession.entrypoint ?? liveSession.kind ?? "cli",
      liveSession: assuredLiveSession,
      desktopSession,
    });
  }

  for (const desktopSession of desktopSessions) {
    if (!desktopSession.cliSessionId || !desktopSession.cwd || threads.has(desktopSession.cliSessionId)) {
      continue;
    }

    threads.set(desktopSession.cliSessionId, {
      threadId: desktopSession.cliSessionId,
      cwd: desktopSession.cwd,
      updatedAt: normalizeUpdatedAt(desktopSession.lastActivityAt ?? desktopSession.createdAt),
      sourceKind: "claude-desktop",
      liveSession: null,
      desktopSession,
    });
  }

  return Array.from(threads.values()).sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt);
}

function threadSummaryFromClaudeThread(thread: ClaudeDiscoveredThread): ThreadSummary {
  const launch = thread.liveSession ? findMatchingLaunchByPID("claude", thread.liveSession.pid) : null;
  const preview = launch
    ? thread.sourceKind === "claude-desktop"
      ? "helm-managed Claude desktop session"
      : "helm-managed Claude Code session"
    : thread.sourceKind === "claude-desktop"
      ? "Claude desktop session"
      : "Active Claude Code session";
  const name = thread.desktopSession?.title?.trim() || path.basename(thread.cwd) || "Claude Code Session";
  return {
    id: thread.threadId,
    name,
    preview,
    cwd: thread.cwd,
    status: statusForUpdatedAt(thread.updatedAt, Boolean(thread.liveSession)),
    updatedAt: thread.updatedAt,
    sourceKind: thread.sourceKind,
    launchSource: launch ? HELM_RUNTIME_LAUNCH_SOURCE : null,
    backendId: "claude-code",
    backendLabel: "Claude Code",
    backendKind: "claude-code",
    controller: null,
  };
}

function normalizeClaudeModel(model: string | undefined, contextMode: StartThreadInput["claudeContextMode"]): string | null {
  const trimmed = model?.trim();
  const baseModel = trimmed && trimmed.length > 0 ? trimmed.replace(/\[1m\]$/i, "") : null;
  if (!baseModel) {
    return null;
  }
  if (contextMode === "1m") {
    return `${baseModel}[1m]`;
  }
  return baseModel;
}

async function waitForClaudeSessionByCWD(
  cwd: string,
  launchedAt: number
): Promise<LiveClaudeSessionRecord> {
  const deadline = Date.now() + CLAUDE_LAUNCH_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const session = readClaudeSessionRecords().find((candidate) => {
      return (candidate.cwd ?? "") === cwd && (candidate.startedAt ?? 0) >= launchedAt;
    });
    if (session?.sessionId && session.cwd) {
      return session as LiveClaudeSessionRecord;
    }

    await new Promise((resolve) => setTimeout(resolve, CLAUDE_POLL_INTERVAL_MS));
  }

  throw new Error(`Timed out waiting for Claude Code session launch in ${cwd}.`);
}

async function waitForClaudeSessionByID(
  threadId: string,
  launchedAt: number
): Promise<LiveClaudeSessionRecord> {
  const deadline = Date.now() + CLAUDE_LAUNCH_TIMEOUT_MS;

  while (Date.now() < deadline) {
    const session = readClaudeSessionRecords().find((candidate) => {
      return candidate.sessionId === threadId && (candidate.startedAt ?? 0) >= launchedAt;
    });
    if (session?.sessionId && session.cwd) {
      return session as LiveClaudeSessionRecord;
    }

    await new Promise((resolve) => setTimeout(resolve, CLAUDE_POLL_INTERVAL_MS));
  }

  throw new Error(`Timed out waiting for Claude Code session resume for ${threadId}.`);
}

function findClaudeThread(threadId: string): ClaudeDiscoveredThread {
  const thread = discoverClaudeThreads().find((entry) => entry.threadId === threadId);
  if (!thread) {
    throw new Error("Claude Code session is no longer available");
  }
  return thread;
}

function findLiveClaudeSession(threadId: string): LiveClaudeSessionRecord {
  const thread = findClaudeThread(threadId);
  if (!thread.liveSession) {
    throw new Error("Claude Code session is not currently running");
  }
  return thread.liveSession;
}

function managedLaunchForClaudeSession(session: LiveClaudeSessionRecord) {
  const launch = findMatchingLaunchByPID("claude", session.pid);
  if (!isRuntimeRelayAvailable(launch)) {
    throw new Error(
      "This Claude Code session is not running through helm integration. Open it from helm or relaunch Claude after enabling helm runtime capture to send turns from iPhone."
    );
  }
  return launch;
}

function launchCwdForClaudeThread(thread: ClaudeDiscoveredThread): string {
  const candidates = [
    thread.cwd,
    thread.desktopSession?.originCwd,
    thread.desktopSession?.cwd,
  ];

  for (const candidate of candidates) {
    const trimmed = candidate?.trim();
    if (trimmed && existsSync(trimmed)) {
      return trimmed;
    }
  }

  return homedir();
}

export class ClaudeCodeBackend extends AgentBackend {
  constructor() {
    const sessionsPath = claudeSessionsPath();
    const wrapperAvailable = hasHelmRuntimeWrapper("claude");
    const available = existsSync(sessionsPath) || wrapperAvailable;

    super({
      id: "claude-code",
      label: "Claude Code",
      kind: "claude-code",
      description: "Local Claude Code session discovery for helm",
      isDefault: false,
      available,
      availabilityDetail: available
        ? wrapperAvailable
          ? "Active Claude desktop and Claude Code sessions on this Mac appear in helm. helm-managed sessions can send turns and interrupts through the live runtime relay."
          : "Active Claude desktop and Claude Code sessions on this Mac appear in helm. Install helm runtime integration to launch new Claude sessions from iPhone."
        : "Claude Code local session state was not found on this Mac.",
      capabilities: {
        threadListing: available,
        threadCreation: available && wrapperAvailable,
        turnExecution: wrapperAvailable,
        turnInterrupt: wrapperAvailable,
        approvals: false,
        planMode: true,
        voiceCommand: false,
        realtimeVoice: false,
        hooksAndSkillsParity: false,
        sharedThreadHandoff: false,
      },
      command: {
        routing: "providerChat",
        approvals: "providerManaged",
        handoff: "sessionResume",
        voiceInput: "unsupported",
        voiceOutput: "none",
        supportsCommandFollowups: false,
        notes:
          "helm discovers Claude desktop and Claude Code sessions on this Mac. Turns and interrupts work for helm-managed Claude sessions through the runtime relay, and an explicit open from helm can relaunch an unmanaged Claude session into that managed path by exact session id.",
      },
    });
  }

  async connect(): Promise<void> {
    return;
  }

  async listThreads(): Promise<ThreadSummary[]> {
    return discoverClaudeThreads().map(threadSummaryFromClaudeThread);
  }

  async startThread(input: StartThreadInput = {}): Promise<JSONValue | undefined> {
    if (!this.summary.capabilities.threadCreation) {
      throw this.unavailableError();
    }

    const cwd = input.cwd?.trim();
    if (!cwd) {
      throw new Error("Claude Code session launch requires a working directory.");
    }

    const args: string[] = [];
    const model = normalizeClaudeModel(input.model, input.claudeContextMode);
    if (model) {
      args.push("--model", model);
    }
    if (input.reasoningEffort?.trim()) {
      args.push("--effort", input.reasoningEffort.trim());
    }

    const launchedAt = Date.now();
    await launchManagedRuntimeDetached({
      runtime: "claude",
      cwd,
      args,
    });

    const session = await waitForClaudeSessionByCWD(cwd, launchedAt - 2_000);
    return {
      thread: threadSummaryFromClaudeThread({
        threadId: session.sessionId,
        cwd: session.cwd,
        updatedAt: normalizeUpdatedAt(session.startedAt),
        sourceKind: session.entrypoint ?? session.kind ?? "cli",
        liveSession: session as LiveClaudeSessionRecord,
        desktopSession: null,
      }),
      launched: true,
      launchMode: "managedShell",
    };
  }

  async readThread(threadId: string): Promise<JSONValue | undefined> {
    const thread = findClaudeThread(threadId);
    const launch = thread.liveSession ? findMatchingLaunchByPID("claude", thread.liveSession.pid) : null;
    const snapshot = readClaudeConversationSnapshot(thread.threadId, thread.cwd);
    const items: JSONValue[] = [
      {
        id: `meta-${thread.threadId}`,
        type: "agentMessage",
        text: isRuntimeRelayAvailable(launch)
          ? "Claude session is running through helm integration. helm can send turns and interrupts through the live runtime relay while Claude keeps its own provider-native session state."
          : thread.sourceKind === "claude-desktop"
            ? "Claude desktop session discovered by helm. Open it from helm to spin up a managed resume for turn execution, or keep observing it read-only from the app catalog."
            : "Claude session discovered by helm. This session was not launched through helm integration, so it is currently read-only from helm.",
      },
    ];

    if (snapshot.latestUserMessage) {
      items.push({
        id: `user-${thread.threadId}`,
        type: "userMessage",
        content: {
          text: snapshot.latestUserMessage,
        },
      });
    }

    if (snapshot.latestAssistantMessage) {
      items.push({
        id: `assistant-${thread.threadId}`,
        type: "agentMessage",
        text: snapshot.latestAssistantMessage,
      });
    }

    return {
      thread: {
        id: thread.threadId,
        name: thread.desktopSession?.title?.trim() || path.basename(thread.cwd) || "Claude Code Session",
        cwd: thread.cwd,
        status: statusForUpdatedAt(thread.updatedAt, Boolean(thread.liveSession)),
        updatedAt: thread.updatedAt,
        turns: [
          {
            id: `turn-${thread.threadId}`,
            status: thread.liveSession ? "running" : "completed",
            items,
          },
        ],
      },
    };
  }

  async startTurn(threadId: string, text: string, options: StartTurnOptions = {}): Promise<JSONValue | undefined> {
    if (options.imageAttachments?.length) {
      throw new Error("Image attachments are only supported for Codex sessions right now.");
    }

    const session = findLiveClaudeSession(threadId);
    const launch = managedLaunchForClaudeSession(session);
    const prompt = textWithFileAttachments(text, options.fileAttachments ?? []);
    if (options.deliveryMode === "interrupt") {
      await interruptViaRuntimeRelay(launch);
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    await sendTextViaRuntimeRelay(launch, prompt);
    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    const session = findLiveClaudeSession(threadId);
    const launch = managedLaunchForClaudeSession(session);
    await interruptViaRuntimeRelay(launch);
    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  async sendInput(threadId: string, input: string): Promise<JSONValue | undefined> {
    const session = findLiveClaudeSession(threadId);
    const launch = managedLaunchForClaudeSession(session);
    await sendInputViaRuntimeRelay(launch, input);
    return {
      ok: true,
      mode: "shellRelayInput",
      threadId,
    };
  }

  async renameThread(_threadId: string, _name: string): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  respond(_id: JSONRPCId, _result: JSONValue): void {
    throw this.unavailableError();
  }

  async ensureManagedSession(threadId: string): Promise<{
    threadId: string;
    launched: boolean;
  }> {
    const thread = findClaudeThread(threadId);
    if (thread.liveSession) {
      const managedLaunch = findMatchingLaunchByPID("claude", thread.liveSession.pid);
      if (isRuntimeRelayAvailable(managedLaunch)) {
        return {
          threadId,
          launched: false,
        };
      }
    }

    const launchedAt = Date.now();
    const launchCwd = launchCwdForClaudeThread(thread);
    await launchManagedRuntimeDetached({
      runtime: "claude",
      cwd: launchCwd,
      args: ["--resume", thread.threadId],
    });

    await waitForClaudeSessionByID(thread.threadId, launchedAt - 2_000);
    return {
      threadId,
      launched: true,
    };
  }

  private unavailableError(): Error {
    return new Error("Claude session rename and provider-mediated responses are not wired into helm yet.");
  }
}

function textWithFileAttachments(text: string, fileAttachments: StartTurnFileAttachment[]): string {
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
