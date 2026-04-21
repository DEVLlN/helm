import test from "node:test";
import assert from "node:assert/strict";

import { CodexAppServerClient, currentPromptDraftFromTerminalTail } from "./codexAppServerClient.js";
import type { JSONValue } from "./types.js";

type CodexClientPrivateHooks = {
  localThreadReadFallback(threadId: string, includeTurns: boolean): Promise<JSONValue | undefined>;
  listThreadsFromAppServer(): Promise<Array<{ name: string | null; preview: string; status: string | null }>>;
  mergeThreadSummary(
    thread: { name: string | null; preview?: string | null; updatedAt: number; status: string | null },
    discovered: { name: string | null; preview?: string | null; updatedAt: number; status: string | null } | null
  ): { name: string | null; preview: string; status: string | null };
  request(method: string, params?: JSONValue): Promise<JSONValue | undefined>;
};

test("Codex CLI thread reads use local rollout before app-server", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  let appServerRequested = false;

  hooks.localThreadReadFallback = async (threadId: string, includeTurns: boolean) => ({
    thread: {
      id: threadId,
      name: "CLI thread",
      preview: "latest",
      cwd: "/tmp/project",
      status: "running",
      updatedAt: 123_000,
      sourceKind: "cli",
      ...(includeTurns ? {
        turns: [
          {
            id: "turn-1",
            status: "completed",
            items: [
              {
                id: "item-1",
                type: "agentMessage",
                text: "latest local rollout text",
              },
            ],
          },
        ],
      } : {}),
    },
  });
  hooks.request = async () => {
    appServerRequested = true;
    throw new Error("app-server should not be called");
  };

  const result = await client.readThread("thread-1");
  const thread = result && typeof result === "object" && !Array.isArray(result)
    ? result.thread
    : null;

  assert.equal(appServerRequested, false);
  assert.equal(
    thread && typeof thread === "object" && !Array.isArray(thread)
      ? thread.sourceKind
      : null,
    "cli"
  );
});

test("Codex CLI prompt draft extraction ignores styled placeholder text", () => {
  const tail = [
    "• Working(10s • esc to interrupt)",
    "› Find and fix a bug in @filename   gpt-5.4 xhigh · Fast off · ~/GitHub/helm-dev",
  ].join("\n");

  assert.equal(currentPromptDraftFromTerminalTail(tail), null);
});

test("Codex CLI prompt draft extraction skips status prompt labels", () => {
  const tail = [
    "• Working(5s • esc to interrupt) › Write tests for @filename   gpt-5.4 xhigh · Fast off",
    "• Explored",
  ].join("\n");

  assert.equal(currentPromptDraftFromTerminalTail(tail), null);
});

test("Codex CLI prompt draft extraction preserves real prompt drafts", () => {
  const tail = [
    "• Working(5s • esc to interrupt) › Write tests for @filename   gpt-5.4 xhigh · Fast off",
    "› keep this draft   gpt-5.4 xhigh · Fast off · ~/GitHub/helm-dev",
  ].join("\n");

  assert.equal(currentPromptDraftFromTerminalTail(tail), "keep this draft");
});

test("Codex oversized thread reads prefer turnless app-server metadata before stale local rollout", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const requestCalls: Array<{ method: string; params?: JSONValue }> = [];

  hooks.localThreadReadFallback = async (threadId: string, includeTurns: boolean) => ({
    thread: {
      id: threadId,
      name: "CLI thread",
      preview: "stale local",
      cwd: "/tmp/project",
      status: "running",
      updatedAt: 123_000,
      sourceKind: "appServer",
      ...(includeTurns ? {
        turns: [
          {
            id: "turn-1",
            status: "completed",
            items: [
              {
                id: "item-1",
                type: "agentMessage",
                text: "stale local rollout text",
              },
            ],
          },
        ],
      } : {}),
    },
  });
  hooks.request = async (method: string, params?: JSONValue) => {
    requestCalls.push({ method, params });
    if (method !== "thread/read") {
      throw new Error(`unexpected method: ${method}`);
    }

    if (params && typeof params === "object" && !Array.isArray(params) && params.includeTurns === true) {
      throw new Error("Max payload size exceeded");
    }

    return {
      thread: {
        id: "thread-1",
        name: "Helm iOS",
        preview: "fresh metadata",
        cwd: "/tmp/project",
        status: { type: "notLoaded" },
        updatedAt: 456_000,
        sourceKind: "cli",
        turns: [],
      },
    };
  };

  const result = await client.readThread("thread-1", {
    allowTurnlessFallback: true,
  });
  const thread = result && typeof result === "object" && !Array.isArray(result)
    ? result.thread
    : null;

  assert.deepEqual(
    requestCalls,
    [
      {
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: true,
        },
      },
      {
        method: "thread/read",
        params: {
          threadId: "thread-1",
          includeTurns: false,
        },
      },
    ]
  );
  assert.equal(
    thread && typeof thread === "object" && !Array.isArray(thread)
      ? Array.isArray(thread.turns)
        ? thread.turns.length
        : 0
      : 0,
    0
  );
  assert.equal(
    thread && typeof thread === "object" && !Array.isArray(thread)
      ? thread.updatedAt
      : null,
    456_000
  );
});

test("Codex thread list merge prefers discovered prompt over degraded remote Helm title", () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;

  const merged = hooks.mergeThreadSummary(
    {
      name: "Helm iOS",
      preview: "Helm iOS",
      updatedAt: 456_000,
      status: "running",
    },
    {
      name: "mobile app support for creating a thread in Codex App OR Codex ClI",
      preview: "mobile app support for creating a thread in Codex App OR Codex ClI",
      updatedAt: 123_000,
      status: "running",
    }
  );

  assert.equal(merged.name, "mobile app support for creating a thread in Codex App OR Codex ClI");
});

test("Codex app-server list rewrites running title-only previews to waiting placeholder", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;

  hooks.request = async (method: string) => {
    assert.equal(method, "thread/list");
    return {
      threads: [
        {
          id: "thread-1",
          name: "Test app and fix bugs",
          preview: "Test app and fix bugs",
          cwd: "/tmp/project",
          status: "running",
          updatedAt: 456_000,
          sourceKind: "vscode",
        },
        {
          id: "thread-2",
          name: "Daily bug scan",
          preview: "Daily bug scan",
          cwd: "/tmp/project",
          status: "idle",
          updatedAt: 455_000,
          sourceKind: "vscode",
        },
      ],
    };
  };

  const threads = await hooks.listThreadsFromAppServer();

  assert.equal(threads[0]?.preview, "Waiting for output...");
  assert.equal(threads[1]?.preview, "No activity yet.");
});

test("recent title-only unknown app-server sessions stay idle", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const now = Date.now();

  hooks.request = async () => ({
    threads: [
      {
        id: "thread-1",
        name: "Resume Gabagool replay logic",
        preview: "Resume Gabagool replay logic",
        cwd: "/tmp/project",
        status: "unknown",
        updatedAt: now,
        sourceKind: "vscode",
      },
    ],
  });

  const threads = await hooks.listThreadsFromAppServer();

  assert.equal(threads[0]?.status, "idle");
  assert.equal(threads[0]?.preview, "No activity yet.");
});
