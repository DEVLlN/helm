import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { BridgeServer, readGitBranchStatus } from "./bridgeServer.js";
import { createCodexAutomation, listCodexAutomations, parseCodexAutomationToml } from "./codexAutomations.js";
import type {
  BackendSummary,
  JSONValue,
  ThreadDetail,
  ThreadDetailItem,
  ThreadDetailTurn,
  ThreadSummary,
} from "./types.js";

type BridgeServerInternals = {
  enrichThreadSummaries(threads: ThreadSummary[]): Promise<ThreadSummary[]>;
  listThreadsForResponse(): Promise<ThreadSummary[]>;
  withControllerMetadata(threads: ThreadSummary[]): ThreadSummary[];
  fallbackThreadDetailForResponse(
    threadId: string,
    summary: ThreadSummary | null,
    options?: {
      includeLiveRuntimeTail?: boolean;
    },
    cached?: ThreadDetail | null
  ): Promise<ThreadDetail | null>;
  readNormalizedThreadDetailForResponse(
    threadId: string,
    options?: {
      includeLiveRuntimeTail?: boolean;
      preferFresh?: boolean;
    }
  ): Promise<ThreadDetail | null>;
  codexComputedThreadName(row: { title?: string | null; first_user_message?: string | null }): string | null;
  compactThreadDetailItem(item: ThreadDetailItem): ThreadDetailItem;
  compactThreadDetailForWebSocket(detail: ThreadDetail): ThreadDetail;
  compactOversizedThreadTurn(turn: ThreadDetailTurn): ThreadDetailTurn;
  mergedThreadPreview(
    primaryPreview: string,
    status: string,
    fallbackPreview?: string | null,
    fallbackName?: string | null
  ): string;
  normalizeThreadItem(value: JSONValue): ThreadDetailItem | null;
  normalizeThreadDetail(
    result: JSONValue | undefined,
    backend: BackendSummary,
    summary?: ThreadSummary | null
  ): ThreadDetail | null;
  preferredThreadStatus(
    primary: string | null,
    fallback: string | null,
    updatedAt: number,
    options?: {
      preferRecentIdle?: boolean;
    }
  ): string;
  resolvedThreadPreview(
    primaryPreview: string,
    status: string,
    fallbackPreview?: string | null,
    fallbackName?: string | null
  ): string;
  threadPreviewFromDetail(detail: ThreadDetail): string;
  threadSummaryNeedsOpportunisticDetailRefresh(thread: ThreadSummary): boolean;
  shouldRefreshPolledThreadDetail(
    summary: ThreadSummary,
    cached: ThreadDetail,
    threadId: string
  ): boolean;
  withLiveRuntimeTail(detail: ThreadDetail, backendId: string): ThreadDetail;
  liveRuntimeOutputTailForThread(threadId: string, backendId: string): { updatedAt: number; text: string } | null;
  codexLocalThreadSnapshot(threadId: string): Promise<{ turns: JSONValue[]; updatedAt: number | null }>;
};

function compactItem(item: ThreadDetailItem): ThreadDetailItem {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  return server.compactThreadDetailItem(item);
}

function normalizeItem(value: JSONValue): ThreadDetailItem | null {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  return server.normalizeThreadItem(value);
}

function compactTurn(turn: ThreadDetailTurn): ThreadDetailTurn {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  return server.compactOversizedThreadTurn(turn);
}

function compactDetailForWebSocket(detail: ThreadDetail): ThreadDetail {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  return server.compactThreadDetailForWebSocket(detail);
}

function withLiveTail(
  detail: ThreadDetail,
  tail: { updatedAt: number; text: string }
): ThreadDetail {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  server.liveRuntimeOutputTailForThread = () => tail;
  return server.withLiveRuntimeTail(detail, "codex");
}

function threadItem(overrides: Partial<ThreadDetailItem>): ThreadDetailItem {
  return {
    id: "item-1",
    turnId: "turn-1",
    type: "agentMessage",
    title: "Codex response",
    detail: null,
    status: "completed",
    rawText: null,
    metadataSummary: null,
    command: null,
    cwd: null,
    exitCode: null,
    ...overrides,
  };
}

function testBackendSummary(): BackendSummary {
  return {
    id: "codex",
    label: "Codex",
    kind: "codex",
    description: "Codex backend",
    isDefault: true,
    available: true,
    capabilities: {
      threadListing: true,
      threadCreation: true,
      turnExecution: true,
      turnInterrupt: true,
      approvals: true,
      planMode: true,
      voiceCommand: false,
      realtimeVoice: false,
      hooksAndSkillsParity: true,
      sharedThreadHandoff: true,
    },
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Test backend.",
    },
  };
}

test("thread detail compaction preserves the tail of long agent messages", () => {
  const prefix = "BEGINNING-ONLY ";
  const suffix = " THE-LATEST-ASSISTANT-TEXT";
  const text = `${prefix}${"middle ".repeat(10_000)}${suffix}`;

  const item = compactItem(threadItem({
    rawText: text,
    detail: text,
  }));

  assert.equal(item.rawText?.endsWith(suffix), true);
  assert.equal(item.detail?.endsWith(suffix), true);
  assert.equal(item.rawText?.includes(prefix), false);
});

test("bridge codex registry naming prefers first user message over degraded Helm title", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.codexComputedThreadName({
      title: "Helm iOS",
      first_user_message: "mobile app support for creating a thread in Codex App OR Codex ClI",
    }),
    "mobile app support for creating a thread in Codex App OR Codex ClI"
  );
});

test("git branch status reports local branches for toolbar branch switching", () => {
  const repo = mkdtempSync(path.join(tmpdir(), "helm-git-branches-"));
  execFileSync("git", ["init", "-b", "main"], { cwd: repo, stdio: "ignore" });
  execFileSync("git", ["config", "user.email", "helm@example.com"], { cwd: repo, stdio: "ignore" });
  execFileSync("git", ["config", "user.name", "Helm Test"], { cwd: repo, stdio: "ignore" });
  writeFileSync(path.join(repo, "README.md"), "helm\n");
  execFileSync("git", ["add", "README.md"], { cwd: repo, stdio: "ignore" });
  execFileSync("git", ["commit", "-m", "init"], { cwd: repo, stdio: "ignore" });
  execFileSync("git", ["branch", "feature/toolbar"], { cwd: repo, stdio: "ignore" });

  assert.deepEqual(readGitBranchStatus(repo), {
    cwd: repo,
    isRepository: true,
    currentBranch: "main",
    branches: ["feature/toolbar", "main"],
  });
});

test("git branch status treats non-repositories as unavailable", () => {
  const directory = mkdtempSync(path.join(tmpdir(), "helm-no-git-"));

  assert.deepEqual(readGitBranchStatus(directory), {
    cwd: directory,
    isRepository: false,
    currentBranch: null,
    branches: [],
  });
});

test("running thread summaries synthesize a waiting preview when detail is blank", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(server.resolvedThreadPreview("", "running"), "Waiting for output...");
  assert.equal(server.resolvedThreadPreview("   ", "running", null), "Waiting for output...");
});

test("thread preview resolution preserves existing nonblank previews", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(server.resolvedThreadPreview("fresh detail", "running", "older"), "fresh detail");
  assert.equal(server.resolvedThreadPreview("", "running", "older"), "older");
  assert.equal(server.resolvedThreadPreview("", "idle", null), "");
});

test("thread previews prefer the newest turn text in newest-first thread order", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const preview = server.threadPreviewFromDetail({
    id: "thread-1",
    name: "Thread",
    cwd: "/tmp/project",
    workspacePath: "/tmp/project",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {} as ThreadDetail["command"],
    affordances: {} as ThreadDetail["affordances"],
    turns: [
      {
        id: "turn-2",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "user-new",
            turnId: "turn-2",
            type: "userMessage",
            title: "User message",
            rawText: "Newest prompt",
            detail: "Newest prompt",
          }),
          threadItem({
            id: "agent-new",
            turnId: "turn-2",
            rawText: "Newest reply",
            detail: "Newest reply",
          }),
        ],
      },
      {
        id: "turn-1",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "user-old",
            turnId: "turn-1",
            type: "userMessage",
            title: "User message",
            rawText: "Older prompt",
            detail: "Older prompt",
          }),
          threadItem({
            id: "agent-old",
            turnId: "turn-1",
            rawText: "Older reply",
            detail: "Older reply",
          }),
        ],
      },
    ],
  });

  assert.equal(preview, "Newest prompt\nNewest reply");
});

test("Codex automation parser extracts schedule and execution metadata", () => {
  const automation = parseCodexAutomationToml(`
version = 1
id = "performance-audit"
kind = "cron"
name = "Performance audit"
prompt = "Audit performance regressions.\\nReport measurements."
status = "ACTIVE"
rrule = "RRULE:FREQ=WEEKLY;BYHOUR=8;BYMINUTE=0;BYDAY=MO"
model = "gpt-5.4"
reasoning_effort = "medium"
execution_environment = "worktree"
cwds = ["/Users/devlin/GitHub/prediction-markets-bot"]
created_at = 1776825539662
updated_at = 1776825539662
`, "/tmp/automation.toml");

  assert.equal(automation?.id, "performance-audit");
  assert.equal(automation?.name, "Performance audit");
  assert.equal(automation?.status, "ACTIVE");
  assert.equal(automation?.scheduleSummary, "Weekly Monday at 8:00 AM");
  assert.equal(automation?.cwd, "/Users/devlin/GitHub/prediction-markets-bot");
  assert.equal(automation?.prompt, "Audit performance regressions.\nReport measurements.");
});

test("Codex automation list reads automation directories and sorts active entries first", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "helm-automations-"));
  mkdirSync(path.join(root, "paused-task"));
  mkdirSync(path.join(root, "active-task"));
  writeFileSync(path.join(root, "paused-task", "automation.toml"), `
id = "paused-task"
kind = "cron"
name = "Paused task"
prompt = "Paused"
status = "PAUSED"
updated_at = 200
`);
  writeFileSync(path.join(root, "active-task", "automation.toml"), `
id = "active-task"
kind = "cron"
name = "Active task"
prompt = "Active"
status = "ACTIVE"
updated_at = 100
`);

  const previous = process.env.CODEX_AUTOMATIONS_DIR;
  process.env.CODEX_AUTOMATIONS_DIR = root;
  try {
    assert.deepEqual(
      (await listCodexAutomations()).map((automation) => automation.id),
      ["active-task", "paused-task"]
    );
  } finally {
    if (previous === undefined) {
      delete process.env.CODEX_AUTOMATIONS_DIR;
    } else {
      process.env.CODEX_AUTOMATIONS_DIR = previous;
    }
  }
});

test("Codex automation creation writes parseable automation files", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "helm-create-automation-"));
  const previous = process.env.CODEX_AUTOMATIONS_DIR;
  process.env.CODEX_AUTOMATIONS_DIR = root;
  try {
    const automation = await createCodexAutomation({
      name: "Daily mobile audit",
      prompt: "Check the mobile app.",
      rrule: "RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      model: "gpt-5.4",
      reasoningEffort: "medium",
      executionEnvironment: "local",
      cwd: "/Users/devlin/GitHub/helm-dev",
      status: "ACTIVE",
    });

    assert.equal(automation.id, "daily-mobile-audit");
    assert.equal(automation.name, "Daily mobile audit");
    assert.equal(automation.scheduleSummary, "Daily at 9:00 AM");
    assert.equal(automation.cwd, "/Users/devlin/GitHub/helm-dev");
    assert.deepEqual(
      (await listCodexAutomations()).map((entry) => entry.id),
      ["daily-mobile-audit"]
    );
  } finally {
    if (previous === undefined) {
      delete process.env.CODEX_AUTOMATIONS_DIR;
    } else {
      process.env.CODEX_AUTOMATIONS_DIR = previous;
    }
  }
});

test("idle thread preview merge prefers fresh detail over stale fallback text", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.mergedThreadPreview(
      "I’m narrowing this to the usual macOS causes and collecting exact references now.",
      "idle",
      "Control Mac mini remotely"
    ),
    "I’m narrowing this to the usual macOS causes and collecting exact references now."
  );
});

test("idle thread preview merge still replaces generic fallback text", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.mergedThreadPreview("fresh detail", "idle", "Codex CLI session"),
    "fresh detail"
  );
});

test("running thread preview merge still prefers live detail updates", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.mergedThreadPreview("fresh running detail", "running", "older stable prompt"),
    "fresh running detail"
  );
  assert.equal(
    server.mergedThreadPreview("", "running", "older stable prompt"),
    "older stable prompt"
  );
});

test("running thread preview merge ignores title-only fallback previews", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.mergedThreadPreview("", "running", "Test app and fix bugs", "Test app and fix bugs"),
    "Waiting for output..."
  );
  assert.equal(
    server.mergedThreadPreview("", "idle", "Daily bug scan", "Daily bug scan"),
    "No activity yet."
  );
});

test("title-echo thread summaries are considered low-signal for enrichment", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.threadSummaryNeedsOpportunisticDetailRefresh({
      id: "thread-1",
      name: "Resume Gabagool replay logic",
      preview: "Resume Gabagool replay logic",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: 123_000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    }),
    true
  );
  assert.equal(
    server.threadSummaryNeedsOpportunisticDetailRefresh({
      id: "thread-2",
      name: "Resume Gabagool replay logic",
      preview: "No activity yet.",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: 123_000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    }),
    false
  );
});

test("recently updated idle summaries still refresh detail even with non-generic previews", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.threadSummaryNeedsOpportunisticDetailRefresh({
      id: "thread-3",
      name: "Add pre-turn message fold",
      preview: "Let's add the pre-turn message fold.",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: Date.now(),
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    }),
    true
  );
  assert.equal(
    server.threadSummaryNeedsOpportunisticDetailRefresh({
      id: "thread-4",
      name: "Older thread",
      preview: "Older but non-generic preview",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: Date.now() - 5 * 60 * 1000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    }),
    false
  );
});

test("thread list preserves backend-provided controller metadata when no local override exists", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const controller = {
    clientId: "codex-desktop",
    clientName: "Codex Desktop",
    claimedAt: 123_000,
    lastSeenAt: 123_000,
  };

  const threads = server.withControllerMetadata([
    {
      id: "thread-1",
      name: "Resume Gabagool replay logic",
      preview: "No activity yet.",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: 123_000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller,
    },
  ]);

  assert.deepEqual(threads[0]?.controller, controller);
});

test("thread list enrichment fetches detail for generic summaries", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const scheduled: string[] = [];
  const requested: string[] = [];

  server.liveCachedThreadDetail = () => null;
  server.scheduleThreadDetailBroadcast = (threadId: string) => {
    scheduled.push(threadId);
  };
  server.readNormalizedThreadDetailForResponse = async (threadId: string) => {
    requested.push(threadId);
    if (threadId !== "thread-1") {
      return null;
    }

    return {
      id: "thread-1",
      name: null,
      cwd: "/Users/devlin/GitHub/helm-dev",
      workspacePath: "/Users/devlin/GitHub/helm-dev",
      status: "idle",
      updatedAt: 123_000,
      sourceKind: "cli",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      command: {
        routing: "threadTurns",
        approvals: "bridgeDecisions",
        handoff: "sharedThread",
        voiceInput: "bridgeRealtime",
        voiceOutput: "bridgeSpeech",
        supportsCommandFollowups: true,
        notes: "Command routes into shared Codex threads on the Mac.",
      },
      affordances: {
        canSendTurns: true,
        canInterrupt: true,
        canRespondToApprovals: true,
        canUseRealtimeCommand: true,
        showsOperationalSnapshot: true,
        sessionAccess: "sharedThread",
        notes: "Shared thread bridge session.",
      },
      turns: [
        {
          id: "turn-1",
          status: "completed",
          error: null,
          items: [
            threadItem({
              id: "user-1",
              type: "userMessage",
              rawText: "Reply with exactly HELM_BOOTSTRAP_OK and do nothing else.",
              detail: "Reply with exactly HELM_BOOTSTRAP_OK and do nothing else.",
              title: "Reply with exactly HELM_BOOTSTRAP_OK and do nothing else.",
            }),
            threadItem({
              id: "agent-1",
              type: "agentMessage",
              rawText: "HELM_BOOTSTRAP_OK",
              detail: "HELM_BOOTSTRAP_OK",
              title: "HELM_BOOTSTRAP_OK",
            }),
          ],
        },
      ],
    } satisfies ThreadDetail;
  };

  const threads: ThreadSummary[] = [
    {
      id: "thread-1",
      name: null,
      preview: "Codex CLI session",
      cwd: "/Users/devlin/GitHub/helm-dev",
      workspacePath: "/Users/devlin/GitHub/helm-dev",
      status: "idle",
      updatedAt: 123_000,
      sourceKind: "cli",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    },
    {
      id: "thread-2",
      name: "Daily bug scan",
      preview: "Daily bug scan",
      cwd: "/Users/devlin/GitHub/prediction-markets-bot",
      workspacePath: "/Users/devlin/GitHub/prediction-markets-bot",
      status: "idle",
      updatedAt: 122_000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    },
  ];

  const enriched = await (server.enrichThreadSummaries as (threads: ThreadSummary[]) => Promise<ThreadSummary[]>)(threads);

  assert.deepEqual(requested, ["thread-1", "thread-2"]);
  assert.deepEqual(scheduled, ["thread-2"]);
  assert.equal(
    enriched.find((thread) => thread.id === "thread-1")?.preview,
    "Reply with exactly HELM_BOOTSTRAP_OK and do nothing else.\nHELM_BOOTSTRAP_OK"
  );
  assert.equal(
    enriched.find((thread) => thread.id === "thread-2")?.preview,
    "Daily bug scan"
  );
});

test("thread list enrichment uses fallback-aware detail reads for recent stale summaries", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  let readCount = 0;

  server.liveCachedThreadDetail = () => null;
  server.scheduleThreadDetailBroadcast = () => {};
  server.readNormalizedThreadDetailForResponse = async () => {
    readCount += 1;
    return {
      id: "thread-1",
      name: "Add pre-turn message fold",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: 124_000,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      command: {
        routing: "threadTurns",
        approvals: "bridgeDecisions",
        handoff: "sharedThread",
        voiceInput: "bridgeRealtime",
        voiceOutput: "bridgeSpeech",
        supportsCommandFollowups: true,
        notes: "Command routes into shared Codex threads on the Mac.",
      },
      affordances: {
        canSendTurns: true,
        canInterrupt: true,
        canRespondToApprovals: true,
        canUseRealtimeCommand: true,
        showsOperationalSnapshot: true,
        sessionAccess: "sharedThread",
        notes: "Shared thread bridge session.",
      },
      turns: [
        {
          id: "turn-1",
          status: "completed",
          error: null,
          items: [
            threadItem({
              id: "user-1",
              turnId: "turn-1",
              type: "userMessage",
              title: "User message",
              rawText: "Latest mobile bridge complaint",
              detail: "Latest mobile bridge complaint",
            }),
            threadItem({
              id: "agent-1",
              turnId: "turn-1",
              rawText: "Fresh detail preview",
              detail: "Fresh detail preview",
            }),
          ],
        },
      ],
    } satisfies ThreadDetail;
  };

  const enriched = await server.enrichThreadSummaries([
    {
      id: "thread-1",
      name: "Add pre-turn message fold",
      preview: "Let's add the pre-turn message fold.",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: Date.now(),
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    },
  ]);

  assert.equal(readCount, 1);
  assert.equal(enriched[0]?.preview, "Latest mobile bridge complaint\nFresh detail preview");
});

test("thread list enrichment refreshes top stale idle summaries from detail", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  let readCount = 0;

  server.liveCachedThreadDetail = () => null;
  server.scheduleThreadDetailBroadcast = () => {};
  server.readNormalizedThreadDetailForResponse = async () => {
    readCount += 1;
    return {
      id: "thread-1",
      name: "Add pre-turn message fold",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: Date.now(),
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      command: {} as ThreadDetail["command"],
      affordances: {} as ThreadDetail["affordances"],
      turns: [
        {
          id: "turn-1",
          status: "completed",
          error: null,
          items: [
            threadItem({
              id: "user-1",
              turnId: "turn-1",
              type: "userMessage",
              title: "User message",
              rawText: "mobile still does not show the most recent messages",
              detail: "mobile still does not show the most recent messages",
            }),
            threadItem({
              id: "agent-1",
              turnId: "turn-1",
              rawText: "The final assistant reply is now available.",
              detail: "The final assistant reply is now available.",
              status: "final_answer",
            }),
          ],
        },
      ],
    } satisfies ThreadDetail;
  };

  const staleUpdatedAt = Date.now() - 60 * 60 * 1000;
  const enriched = await server.enrichThreadSummaries([
    {
      id: "thread-1",
      name: "Add pre-turn message fold",
      preview: "The code change is in. I'm running a focused iOS test slice first.",
      cwd: "/tmp/project",
      workspacePath: "/tmp/project",
      status: "idle",
      updatedAt: staleUpdatedAt,
      sourceKind: "vscode",
      launchSource: null,
      backendId: "codex",
      backendLabel: "Codex",
      backendKind: "codex",
      controller: null,
    },
  ]);

  assert.equal(readCount, 1);
  assert.equal(
    enriched[0]?.preview,
    "mobile still does not show the most recent messages\nThe final assistant reply is now available."
  );
  assert.ok((enriched[0]?.updatedAt ?? 0) > staleUpdatedAt);
});

test("thread list response overlays fresher cached detail onto stale cached summaries", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const staleSummary: ThreadSummary = {
    id: "thread-1",
    name: "Test app and fix bugs",
    preview: "Waiting for output...",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  server.threadListCache = {
    threads: [staleSummary],
    updatedAt: 123_000,
  };
  server.refreshThreadListCache = async () => [staleSummary];
  server.liveCachedThreadDetail = () => ({
    id: "thread-1",
    name: "Test app and fix bugs",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 124_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [
      {
        id: "turn-1",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "agent-1",
            turnId: "turn-1",
            type: "agentMessage",
            rawText: "continue please",
            detail: "continue please",
            title: "Codex response",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail);

  const threads = await server.listThreadsForResponse();

  assert.equal(threads.length, 1);
  assert.equal(threads[0]?.preview, "continue please");
  assert.equal(threads[0]?.updatedAt, 124_000);
});

test("thread detail fallback uses local codex turns before an empty placeholder", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Test app and fix bugs",
    preview: "Waiting for output...",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  server.codexLocalThreadTurns = async () => [
    {
      id: "turn-1",
      status: "completed",
      items: [
        {
          id: "user-1",
          type: "userMessage",
          content: {
            text: "Investigate the stuck waiting placeholder.\n",
          },
        },
      ],
    },
  ];

  const detail = await server.fallbackThreadDetailForResponse(summary.id, summary);

  assert.equal(detail?.status, "running");
  assert.equal(detail?.workspacePath, "/Users/devlin/GitHub/helm-dev");
  assert.equal(detail?.turns.length, 1);
  assert.equal(detail?.turns[0]?.items[0]?.title, "User message");
  assert.equal(
    detail?.turns[0]?.items[0]?.detail?.trim(),
    "Investigate the stuck waiting placeholder."
  );
});

test("thread detail fallback prefers fuller local codex turns over stale cached detail", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Add pre-turn message fold",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  const cachedDetail = {
    id: "thread-1",
    name: "Add pre-turn message fold",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 122_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [
      {
        id: "turn-older",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "cached-user",
            turnId: "turn-older",
            type: "userMessage",
            title: "User message",
            rawText: "Older prompt",
            detail: "Older prompt",
          }),
          threadItem({
            id: "cached-agent",
            turnId: "turn-older",
            rawText: "Older reply",
            detail: "Older reply",
          }),
        ],
      },
      {
        id: "turn-oldest",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "cached-agent-2",
            turnId: "turn-oldest",
            rawText: "Oldest reply",
            detail: "Oldest reply",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail;

  server.codexLocalThreadTurns = async () => [
    {
      id: "turn-live",
      status: "running",
      items: [
        {
          id: "user-live",
          type: "userMessage",
          content: {
            text: "continue. had to restart my comp.\n",
          },
        },
        {
          id: "agent-live",
          type: "agentMessage",
          text: "The bridge detail is still behind the desktop thread.",
          phase: "commentary",
        },
      ],
    },
    {
      id: "turn-older",
      status: "completed",
      items: [
        {
          id: "cached-user",
          type: "userMessage",
          content: {
            text: "Older prompt\n",
          },
        },
        {
          id: "cached-agent",
          type: "agentMessage",
          text: "Older reply",
          phase: "final_answer",
        },
      ],
    },
    {
      id: "turn-oldest",
      status: "completed",
      items: [
        {
          id: "cached-agent-2",
          type: "agentMessage",
          text: "Oldest reply",
          phase: "final_answer",
        },
      ],
    },
  ];

  const detail = await server.fallbackThreadDetailForResponse(summary.id, summary, {}, cachedDetail);

  assert.equal(detail?.turns.length, 3);
  assert.equal(detail?.turns[0]?.id, "turn-live");
  assert.equal(detail?.turns[0]?.items[0]?.detail?.trim(), "continue. had to restart my comp.");
});

test("thread detail response prefers local codex turns over an empty live read", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Test app and fix bugs",
    preview: "Waiting for output...",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  server.liveCachedThreadDetail = () => ({
    id: "thread-1",
    name: "Test app and fix bugs",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 122_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [],
  } satisfies ThreadDetail);
  server.cachedThreadSummary = () => summary;
  server.discoverLocalCodexThreadSummary = async () => summary;
  server.codexLocalThreadTurns = async () => [
    {
      id: "turn-1",
      status: "completed",
      items: [
        {
          id: "agent-1",
          type: "agentMessage",
          text: "Recovered local rollout detail.",
        },
      ],
    },
  ];
  server.readNormalizedThreadDetailCoalesced = async () => ({
    id: "thread-1",
    name: "Test app and fix bugs",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 124_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [],
  } satisfies ThreadDetail);

  const detail = await server.readNormalizedThreadDetailForResponse(summary.id);

  assert.equal(detail?.turns.length, 1);
  assert.equal(detail?.turns[0]?.items[0]?.detail, "Recovered local rollout detail.");
});

test("thread detail response prefers fuller local codex fallback over stale live detail", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Add pre-turn message fold",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  const staleDetail = {
    id: "thread-1",
    name: "Add pre-turn message fold",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 122_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [
      {
        id: "turn-older",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "cached-agent",
            turnId: "turn-older",
            rawText: "Older reply",
            detail: "Older reply",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail;

  server.liveCachedThreadDetail = () => staleDetail;
  server.cachedThreadSummary = () => summary;
  server.discoverLocalCodexThreadSummary = async () => summary;
  server.codexLocalThreadTurns = async () => [
    {
      id: "turn-live",
      status: "running",
      items: [
        {
          id: "agent-live",
          type: "agentMessage",
          text: "Fresh rollout detail.",
          phase: "commentary",
        },
        {
          id: "command-live",
          type: "commandExecution",
          command: "/bin/zsh -lc git status --short",
          status: "completed",
          aggregatedOutput: " M bridge/src/bridgeServer.ts\n",
        },
      ],
    },
    {
      id: "turn-older",
      status: "completed",
      items: [
        {
          id: "cached-agent",
          type: "agentMessage",
          text: "Older reply",
          phase: "final_answer",
        },
      ],
    },
  ];
  server.readNormalizedThreadDetailCoalesced = async () => staleDetail;

  const detail = await server.readNormalizedThreadDetailForResponse(summary.id);

  assert.equal(detail?.turns.length, 2);
  assert.equal(detail?.turns[0]?.id, "turn-live");
  assert.equal(detail?.turns[0]?.items[0]?.detail, "Fresh rollout detail.");
});

test("thread detail response prefers newer local codex fallback over larger stale cache", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Fix mobile feed recent messages",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "idle",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
  const staleUpdatedAt = Date.parse("2026-04-23T21:11:57.524Z");
  const freshUpdatedAt = Date.parse("2026-04-23T21:17:58.007Z");
  const staleItems = Array.from({ length: 30 }, (_, index) => (
    threadItem({
      id: `local-command-${index + 1}`,
      turnId: "turn-live",
      type: "commandExecution",
      title: `/bin/zsh -lc stale-${index + 1}`,
      rawText: `stale output ${index + 1}`,
      detail: `stale output ${index + 1}`,
    })
  ));
  const staleDetail = {
    id: summary.id,
    name: summary.name,
    cwd: summary.cwd,
    workspacePath: summary.workspacePath,
    status: "idle",
    updatedAt: staleUpdatedAt,
    sourceKind: summary.sourceKind,
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {} as ThreadDetail["command"],
    affordances: {} as ThreadDetail["affordances"],
    turns: [
      {
        id: "turn-live",
        status: "running",
        error: null,
        items: staleItems,
      },
      {
        id: "turn-older",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "local-agent-older",
            turnId: "turn-older",
            rawText: "Older final reply",
            detail: "Older final reply",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail;

  server.liveCachedThreadDetail = () => staleDetail;
  server.cachedThreadSummary = () => summary;
  server.discoverLocalCodexThreadSummary = async () => summary;
  server.readNormalizedThreadDetailCoalesced = async () => staleDetail;
  const freshTurns: JSONValue[] = [
    {
      id: "turn-live",
      status: "running",
      items: [
        {
          id: "local-user-1",
          type: "userMessage",
          content: { text: "Fix the final message stall." },
        },
        {
          id: "local-agent-31",
          type: "agentMessage",
          text: "The bridge still has stale cached material.",
          phase: "commentary",
        },
        {
          id: "local-command-32",
          type: "commandExecution",
          command: "/bin/zsh -lc curl fresh detail",
          status: "completed",
          aggregatedOutput: "apiUpdatedAt=2026-04-23T21:17:58Z",
        },
      ],
    },
  ];
  server.codexLocalThreadSnapshot = async () => ({
    updatedAt: freshUpdatedAt,
    turns: freshTurns,
  });

  const detail = await server.readNormalizedThreadDetailForResponse(summary.id, {
    preferFresh: true,
  });
  const latestTurn = detail?.turns.find((turn) => turn.id === "turn-live");

  assert.equal(detail?.updatedAt, freshUpdatedAt);
  assert.equal(latestTurn?.items.at(-1)?.id, "local-command-32");
  assert.equal(detail?.turns.some((turn) => turn.id === "turn-older"), true);
});

test("thread detail response stamps local codex fallback with rollout freshness", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Fix mobile feed recent messages",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
  const rolloutUpdatedAt = Date.parse("2026-04-23T20:57:20.200Z");

  server.liveCachedThreadDetail = () => null;
  server.cachedThreadSummary = () => summary;
  server.discoverLocalCodexThreadSummary = async () => summary;
  server.readNormalizedThreadDetailCoalesced = async () => null;
  server.codexLocalThreadSnapshot = async () => ({
    updatedAt: rolloutUpdatedAt,
    turns: [
      {
        id: "turn-live",
        status: "running",
        items: [
          {
            id: "command-live",
            type: "commandExecution",
            command: "/bin/zsh -lc git status --short",
            status: "completed",
          },
        ],
      },
    ],
  });

  const detail = await server.readNormalizedThreadDetailForResponse(summary.id, {
    preferFresh: true,
  });

  assert.equal(detail?.updatedAt, rolloutUpdatedAt);
  assert.equal(detail?.turns[0]?.items[0]?.title, "/bin/zsh -lc git status --short");
});

test("polled Codex detail keeps refreshing across the completion boundary", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const threadId = "thread-1";
  const now = Date.now();
  const summary: ThreadSummary = {
    id: threadId,
    name: "Fix mobile feed recent messages",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "idle",
    updatedAt: now - 60_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
  const cachedDetail = {
    id: threadId,
    name: "Fix mobile feed recent messages",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "running",
    updatedAt: now - 1_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {
      routing: "threadTurns",
      approvals: "bridgeDecisions",
      handoff: "sharedThread",
      voiceInput: "bridgeRealtime",
      voiceOutput: "bridgeSpeech",
      supportsCommandFollowups: true,
      notes: "Command routes into shared Codex threads on the Mac.",
    },
    affordances: {
      canSendTurns: true,
      canInterrupt: true,
      canRespondToApprovals: true,
      canUseRealtimeCommand: true,
      showsOperationalSnapshot: true,
      sessionAccess: "sharedThread",
      notes: "Shared thread bridge session.",
    },
    turns: [
      {
        id: "turn-live",
        status: "running",
        error: null,
        items: [
          threadItem({
            id: "agent-live",
            turnId: "turn-live",
            rawText: "Almost done; final reply is about to land.",
            detail: "Almost done; final reply is about to land.",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail;

  server.threadDetailPollRefreshAt = new Map([[threadId, now - 1_000]]);

  assert.equal(
    server.shouldRefreshPolledThreadDetail(summary, cachedDetail, threadId),
    true
  );
});

test("recent idle Codex details keep trailing refreshes for final-message pickup", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const threadId = "thread-1";
  const now = Date.now();
  const summary: ThreadSummary = {
    id: threadId,
    name: "Fix mobile feed recent messages",
    preview: "Older cached preview",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "idle",
    updatedAt: now - 60_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
  const cachedDetail = {
    id: threadId,
    name: "Fix mobile feed recent messages",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "idle",
    updatedAt: now - 1_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {} as ThreadDetail["command"],
    affordances: {} as ThreadDetail["affordances"],
    turns: [
      {
        id: "turn-live",
        status: "completed",
        error: null,
        items: [
          threadItem({
            id: "agent-live",
            turnId: "turn-live",
            rawText: "The most recent final reply.",
            detail: "The most recent final reply.",
          }),
        ],
      },
    ],
  } satisfies ThreadDetail;

  server.threadDetailPollRefreshAt = new Map([[threadId, now - 3_000]]);

  assert.equal(
    server.shouldRefreshPolledThreadDetail(summary, cachedDetail, threadId),
    true
  );
});

test("thread detail fallback publication updates stale thread list previews", async () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals & Record<string, unknown>;
  const summary: ThreadSummary = {
    id: "thread-1",
    name: "Test app and fix bugs",
    preview: "Waiting for output...",
    cwd: "/Users/devlin/GitHub/helm-dev",
    workspacePath: "/Users/devlin/GitHub/helm-dev",
    status: "idle",
    updatedAt: 123_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };

  server.threadListCache = {
    threads: [summary],
    updatedAt: 123_000,
  };
  server.refreshThreadListCache = async () => (
    (server.threadListCache as { threads: ThreadSummary[] }).threads
  );
  server.readNormalizedThreadDetailCoalesced = async () => null;
  server.codexLocalThreadTurns = async () => [
    {
      id: "turn-1",
      status: "completed",
      items: [
        {
          id: "agent-1",
          type: "agentMessage",
          text: "Fresh local transcript text.",
        },
      ],
    },
  ];

  const detail = await server.readNormalizedThreadDetailForResponse(summary.id);
  const threads = await server.listThreadsForResponse();

  assert.equal(detail?.turns.length, 1);
  assert.equal(threads[0]?.preview, "Fresh local transcript text.");
  assert.equal(threads[0]?.updatedAt, detail?.updatedAt);
});

test("recent empty thread details do not infer running without turns", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const backend = testBackendSummary();
  const detail = server.normalizeThreadDetail(
    {
      thread: {
        id: "thread-1",
        name: "Resume Gabagool replay logic",
        cwd: "/tmp/project",
        updatedAt: Date.now(),
        turns: [],
      },
    },
    backend
  );

  assert.equal(detail?.status, "idle");
});

test("normalized thread details keep the newest turns when trimming newest-first histories", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const backend = testBackendSummary();
  const turns = Array.from({ length: 18 }, (_, index) => {
    const turnNumber = 18 - index;
    return {
      id: `turn-${turnNumber}`,
      status: "completed",
      items: [
        {
          id: `user-${turnNumber}`,
          type: "userMessage",
          content: {
            text: `Prompt ${turnNumber}`,
          },
        },
      ],
    };
  });

  const detail = server.normalizeThreadDetail(
    {
      thread: {
        id: "thread-1",
        name: "Thread",
        cwd: "/tmp/project",
        updatedAt: Date.now(),
        turns,
      },
    },
    backend
  );

  assert.deepEqual(
    detail?.turns.map((turn) => turn.id),
    [
      "turn-18",
      "turn-17",
      "turn-16",
      "turn-15",
      "turn-14",
      "turn-13",
      "turn-12",
      "turn-11",
      "turn-10",
      "turn-9",
      "turn-8",
      "turn-7",
      "turn-6",
      "turn-5",
      "turn-4",
      "turn-3",
    ]
  );
});

test("preferredThreadStatus can demote recent unknown summaries to idle", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.preferredThreadStatus(null, null, Date.now(), {
      preferRecentIdle: true,
    }),
    "idle"
  );
});

test("thread detail compaction still preserves the head of long user messages", () => {
  const prefix = "USER-START ";
  const suffix = " USER-END";
  const text = `${prefix}${"middle ".repeat(1_000)}${suffix}`;

  const item = compactItem(threadItem({
    type: "userMessage",
    title: "User message",
    rawText: text,
    detail: text,
  }));

  assert.equal(item.rawText?.startsWith(prefix), true);
  assert.equal(item.detail?.startsWith(prefix), true);
  assert.equal(item.rawText?.includes(suffix), false);
});

test("command execution normalization keeps full output before terminal tail compaction", () => {
  const prefix = "COMMAND-START ";
  const suffix = " COMMAND-LATEST-OUTPUT";
  const output = `${prefix}${"stdout ".repeat(10_000)}${suffix}`;

  const normalized = normalizeItem({
    id: "command-1",
    type: "commandExecution",
    command: "npm test",
    status: "completed",
    aggregatedOutput: output,
  });

  assert.ok(normalized);
  assert.equal(normalized.rawText, output);

  const compacted = compactItem(normalized);
  assert.equal(compacted.rawText?.endsWith(suffix), true);
  assert.equal(compacted.rawText?.includes(prefix), false);
});

test("thread detail appends a turn-level file change summary after the final answer", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const detail = server.normalizeThreadDetail(
    {
      thread: {
        id: "thread-1",
        name: "Thread",
        cwd: "/tmp/project",
        status: "idle",
        updatedAt: Date.now(),
        turns: [{
          id: "turn-1",
          status: "completed",
          items: [
            {
              id: "change-1",
              type: "fileChange",
              status: "completed",
              changes: [{
                path: "/tmp/project/ios/Sources/SessionFeedView.swift",
                type: "modified",
                unified_diff: "@@ -1 +1 @@\n-old\n+new",
              }],
            },
            {
              id: "change-2",
              type: "fileChange",
              status: "completed",
              changes: [{
                path: "/tmp/project/ios/Tests/CodexVoiceRemoteTests.swift",
                type: "modified",
                unified_diff: "@@ -2 +2 @@\n-old\n+new",
              }],
            },
            {
              id: "agent-final",
              type: "agentMessage",
              phase: "final_answer",
              text: "Fixed it.",
            },
          ],
        }],
      },
    },
    testBackendSummary()
  );

  const items = detail?.turns[0]?.items ?? [];
  const summaryItem = items.at(-1);
  assert.equal(items.at(-2)?.id, "agent-final");
  assert.equal(summaryItem?.id, "turn-file-change-summary-turn-1");
  assert.equal(summaryItem?.type, "fileChange");
  assert.equal(summaryItem?.title, "2 files changed");
  assert.equal(
    summaryItem?.detail,
    "2 files changed | 2 modified | /tmp/project/ios/Sources/SessionFeedView.swift, /tmp/project/ios/Tests/CodexVoiceRemoteTests.swift"
  );
  assert.match(summaryItem?.rawText ?? "", /SessionFeedView\.swift/);
  assert.match(summaryItem?.rawText ?? "", /CodexVoiceRemoteTests\.swift/);
});

test("thread detail keeps a file change summary at the tail of running turns", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  const detail = server.normalizeThreadDetail(
    {
      thread: {
        id: "thread-1",
        name: "Thread",
        cwd: "/tmp/project",
        status: "running",
        updatedAt: Date.now(),
        turns: [{
          id: "turn-1",
          status: "running",
          items: [
            {
              id: "change-1",
              type: "fileChange",
              status: "completed",
              changes: [{
                path: "/tmp/project/bridge/src/bridgeServer.ts",
                type: "modified",
                unified_diff: "@@ -1 +1 @@\n-old\n+new",
              }],
            },
            {
              id: "agent-progress",
              type: "agentMessage",
              phase: "commentary",
              text: "I am checking the live payload now.",
            },
            {
              id: "command-1",
              type: "commandExecution",
              command: "git diff --check",
              status: "completed",
              aggregatedOutput: "",
            },
          ],
        }],
      },
    },
    testBackendSummary()
  );

  const items = detail?.turns[0]?.items ?? [];
  const summaryItem = items.at(-1);
  assert.equal(summaryItem?.id, "turn-file-change-summary-turn-1");
  assert.equal(summaryItem?.title, "1 file changed");
  assert.equal(summaryItem?.detail, "1 file changed | 1 modified | /tmp/project/bridge/src/bridgeServer.ts");
  assert.match(summaryItem?.rawText ?? "", /bridgeServer\.ts/);
});

test("oversized turns preserve the newest terminal rows instead of only conversation rows", () => {
  const items: ThreadDetailItem[] = [
    threadItem({
      id: "user-1",
      type: "userMessage",
      title: "User message",
      rawText: "start",
      detail: "start",
    }),
  ];

  for (let index = 0; index < 30; index += 1) {
    items.push(threadItem({
      id: `file-${index}`,
      type: "fileChange",
      title: "File changes",
      rawText: `file change ${index}`,
      detail: `file change ${index}`,
    }));
  }

  items.push(threadItem({
    id: "latest-command",
    type: "commandExecution",
    title: "npm test",
    rawText: "latest terminal output",
    detail: "latest terminal output",
  }));
  items.push(threadItem({
    id: "latest-agent",
    type: "agentMessage",
    title: "Codex response",
    rawText: "latest assistant text",
    detail: "latest assistant text",
  }));

  const compacted = compactTurn({
    id: "turn-1",
    status: "running",
    error: null,
    items,
  });

  assert.equal(compacted.items[0]?.id, "user-1");
  assert.equal(compacted.items.includes(items.at(-2)!), true);
  assert.equal(compacted.items.at(-1)?.id, "latest-agent");
  assert.ok(compacted.items.length <= 24);
});

test("oversized turns preserve the latest plan item for pinned task lists", () => {
  const items: ThreadDetailItem[] = [
    threadItem({
      id: "user-1",
      type: "userMessage",
      title: "User message",
      rawText: "start",
      detail: "start",
    }),
    threadItem({
      id: "plan-1",
      type: "plan",
      title: "2 out of 5 tasks completed",
      rawText: [
        "2 out of 5 tasks completed",
        "✓ Rank replay blockers",
        "✓ Inspect diagnostics",
        "◉ Patch passive completion hold gate",
        "□ Run focused replay/tests",
        "□ Commit and push",
      ].join("\n"),
      detail: [
        "2 out of 5 tasks completed",
        "✓ Rank replay blockers",
        "✓ Inspect diagnostics",
        "◉ Patch passive completion hold gate",
        "□ Run focused replay/tests",
        "□ Commit and push",
      ].join("\n"),
    }),
  ];

  for (let index = 0; index < 30; index += 1) {
    items.push(threadItem({
      id: `command-${index}`,
      type: "commandExecution",
      title: "Terminal",
      rawText: `command output ${index}`,
      detail: `command output ${index}`,
    }));
  }

  const compacted = compactTurn({
    id: "turn-1",
    status: "running",
    error: null,
    items,
  });

  assert.equal(compacted.items[0]?.id, "user-1");
  assert.equal(compacted.items.some((item) => item.id === "plan-1"), true);
  assert.equal(compacted.items.at(-1)?.id, "command-29");
  assert.ok(compacted.items.length <= 24);
});

test("live runtime tail is appended as the newest turn without lowering detail timestamp", () => {
  const detail: ThreadDetail = {
    id: "thread-1",
    name: "Thread",
    cwd: "/tmp",
    workspacePath: "/tmp",
    status: "running",
    updatedAt: 300,
    sourceKind: "cli",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {} as ThreadDetail["command"],
    affordances: {} as ThreadDetail["affordances"],
    turns: [{
      id: "turn-1",
      status: "completed",
      error: null,
      items: [
        threadItem({
          id: "agent-1",
          turnId: "turn-1",
          type: "agentMessage",
          rawText: "older response",
        }),
      ],
    }],
  };

  const withTail = withLiveTail(detail, {
    updatedAt: 200,
    text: "latest live terminal text",
  });

  assert.equal(withTail.updatedAt, 300);
  assert.deepEqual(withTail.turns.map((turn) => turn.id), [
    "turn-1",
    "live-tail-thread-1",
  ]);
  assert.equal(withTail.turns.at(-1)?.items[0]?.rawText, "latest live terminal text");
});

test("websocket thread detail compaction fits the frame budget and preserves the live tail", () => {
  const liveTailSuffix = " LATEST-LIVE-TAIL";
  const turns: ThreadDetailTurn[] = [];

  for (let turnIndex = 0; turnIndex < 14; turnIndex += 1) {
    const items: ThreadDetailItem[] = [];
    for (let itemIndex = 0; itemIndex < 12; itemIndex += 1) {
      items.push(threadItem({
        id: `item-${turnIndex}-${itemIndex}`,
        turnId: `turn-${turnIndex}`,
        type: itemIndex % 3 === 0 ? "commandExecution" : "agentMessage",
        rawText: `BEGIN-${turnIndex}-${itemIndex} ${"payload ".repeat(10_000)} END-${turnIndex}-${itemIndex}`,
        detail: `BEGIN-${turnIndex}-${itemIndex} ${"payload ".repeat(10_000)} END-${turnIndex}-${itemIndex}`,
      }));
    }
    turns.push({
      id: `turn-${turnIndex}`,
      status: "completed",
      error: null,
      items,
    });
  }

  turns.push({
    id: "live-tail-thread-1",
    status: "running",
    error: null,
    items: [
      threadItem({
        id: "live-tail-item",
        turnId: "live-tail-thread-1",
        type: "commandExecution",
        rawText: `${"old-terminal ".repeat(20_000)}${liveTailSuffix}`,
        detail: `${"old-terminal ".repeat(20_000)}${liveTailSuffix}`,
      }),
    ],
  });

  const compacted = compactDetailForWebSocket({
    id: "thread-1",
    name: "Thread",
    cwd: "/tmp",
    workspacePath: "/tmp",
    status: "running",
    updatedAt: 300,
    sourceKind: "cli",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    command: {} as ThreadDetail["command"],
    affordances: {} as ThreadDetail["affordances"],
    turns,
  });

  const frame = JSON.stringify({
    type: "helm.thread.detail",
    payload: {
      thread: compacted,
    },
  });

  assert.ok(Buffer.byteLength(frame, "utf8") < 3_500_000);
  assert.ok(compacted.turns.length <= 8);
  assert.equal(compacted.turns.at(-1)?.id, "live-tail-thread-1");
  assert.equal(compacted.turns.at(-1)?.items[0]?.rawText?.endsWith(liveTailSuffix), true);
  assert.equal(compacted.turns.at(-1)?.items[0]?.rawText?.includes("old-terminal"), true);
});
