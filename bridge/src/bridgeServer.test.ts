import test from "node:test";
import assert from "node:assert/strict";

import { BridgeServer } from "./bridgeServer.js";
import type {
  BackendSummary,
  JSONValue,
  ThreadDetail,
  ThreadDetailItem,
  ThreadDetailTurn,
  ThreadSummary,
} from "./types.js";

type BridgeServerInternals = {
  listThreadsForResponse(): Promise<ThreadSummary[]>;
  withControllerMetadata(threads: ThreadSummary[]): ThreadSummary[];
  fallbackThreadDetailForResponse(
    threadId: string,
    summary: ThreadSummary | null,
    options?: {
      includeLiveRuntimeTail?: boolean;
    }
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
  threadSummaryNeedsOpportunisticDetailRefresh(thread: ThreadSummary): boolean;
  withLiveRuntimeTail(detail: ThreadDetail, backendId: string): ThreadDetail;
  liveRuntimeOutputTailForThread(threadId: string, backendId: string): { updatedAt: number; text: string } | null;
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

test("idle thread preview merge preserves a stable concise fallback", () => {
  const server = new BridgeServer() as unknown as BridgeServerInternals;
  assert.equal(
    server.mergedThreadPreview(
      "I’m narrowing this to the usual macOS causes and collecting exact references now.",
      "idle",
      "Control Mac mini remotely"
    ),
    "Control Mac mini remotely"
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
  server.readNormalizedThreadDetail = async (threadId: string) => {
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
  const backend: BackendSummary = {
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
