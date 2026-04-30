import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { WebSocketServer } from "ws";

import { CodexAppServerClient, currentPromptDraftFromTerminalTail } from "./codexAppServerClient.js";
import { codexProjectNameForPath } from "./codexProjectNames.js";
import type { JSONValue } from "./types.js";

type TestStartTurnOptions = {
  deliveryMode?: "queue" | "steer" | "interrupt";
  imageAttachments?: Array<{ path: string; filename?: string; mimeType?: string }>;
  fileAttachments?: Array<{ path: string; filename?: string; mimeType?: string }>;
};

type TestQueuedFollowUp = {
  id: string;
  text: string;
  context: {
    prompt: string;
    addedFiles: JSONValue[];
    fileAttachments: JSONValue[];
    commentAttachments: JSONValue[];
    ideContext: JSONValue | null;
    imageAttachments: JSONValue[];
    workspaceRoots: string[];
    collaborationMode: JSONValue | null;
  };
  cwd: string | null;
  createdAt: number;
};

type CodexClientPrivateHooks = {
  localThreadReadFallback(threadId: string, includeTurns: boolean): Promise<JSONValue | undefined>;
  applyCodexDesktopWorkspaceFocus(threads: Array<{
    id: string;
    cwd: string;
    workspacePath?: string | null;
    updatedAt: number;
    sourceKind: string | null;
    controller?: {
      clientId: string;
      clientName: string;
      claimedAt: number;
      lastSeenAt: number;
    } | null;
  }>): Promise<Array<{
    id: string;
    cwd: string;
    workspacePath?: string | null;
    updatedAt: number;
    sourceKind: string | null;
    controller?: {
      clientId: string;
      clientName: string;
      claimedAt: number;
      lastSeenAt: number;
    } | null;
  }>>;
  listThreadsFromAppServer(): Promise<Array<{
    id?: string;
    cwd?: string;
    sourceKind?: string | null;
    projectName?: string | null;
    updatedAt?: number;
    name: string | null;
    preview: string;
    status: string | null;
    controller?: {
      clientId: string;
      clientName: string;
      claimedAt: number;
      lastSeenAt: number;
    } | null;
  }>>;
  mergeThreadSummary(
    thread: { name: string | null; preview?: string | null; updatedAt: number; status: string | null },
    discovered: { name: string | null; preview?: string | null; updatedAt: number; status: string | null } | null
  ): { name: string | null; preview: string; status: string | null };
  request(method: string, params?: JSONValue): Promise<JSONValue | undefined>;
  readCodexDesktopActiveWorkspaceRoots(): Promise<string[]>;
  loadThreadDeliverySummary(threadId: string): Promise<{ sourceKind?: string | null; status?: string | null } | null>;
  readThreadDeliverySnapshot(threadId: string, text: string): Promise<{
    hasTurnData: boolean;
    turnCount: number;
    matchingUserTextCount: number;
    updatedAt: number;
    threadStatus: string | null;
    activeTurnId: string | null;
  } | null>;
  ensureManagedShellThread(threadId: string, options?: { launchManagedShell?: boolean; preferVisibleLaunch?: boolean }): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
    cwd: string;
  }>;
  shouldStartViaAppServer(threadId: string): Promise<boolean>;
  shouldPreferCLIResumeFallback(threadId: string): Promise<boolean>;
  shouldPreferShellRelayFirst(threadId: string): Promise<boolean>;
  setModelAndReasoningViaCodexDesktopIpc(
    threadId: string,
    model: string,
    reasoningEffort: string | null
  ): Promise<JSONValue | undefined>;
  enqueueTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: TestStartTurnOptions,
    thread: { cwd: string; sourceKind?: string | null }
  ): Promise<JSONValue | undefined>;
  startTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: TestStartTurnOptions,
    baseline: unknown
  ): Promise<JSONValue | undefined>;
  steerTurnViaCodexDesktopIpc(
    threadId: string,
    text: string,
    options: TestStartTurnOptions,
    thread: { cwd?: string; sourceKind?: string | null },
    baseline: unknown
  ): Promise<JSONValue | undefined>;
  codexDesktopQueuedFollowUpsWithAppendedMessage(
    currentMessages: TestQueuedFollowUp[],
    message: TestQueuedFollowUp
  ): TestQueuedFollowUp[];
};

test("Codex app-server client initializes over websocket unix socket transport", async (t) => {
  if (process.platform === "win32") {
    return;
  }

  const directory = mkdtempSync(path.join(tmpdir(), "codex-app-server-unix-"));
  const socketPath = path.join(directory, "app.sock");
  const server = http.createServer();
  const sockets = new WebSocketServer({
    server,
    perMessageDeflate: false,
  });

  sockets.on("connection", (socket) => {
    socket.once("message", (data) => {
      const request = JSON.parse(data.toString()) as {
        id: string | number;
        method?: string;
      };
      assert.equal(request.method, "initialize");
      socket.send(JSON.stringify({
        id: request.id,
        result: {
          userAgent: "fake-codex",
          codexHome: directory,
          platformFamily: "unix",
          platformOs: "macos",
        },
      }), () => socket.close());
    });
  });

  t.after(() => {
    for (const client of sockets.clients) {
      client.terminate();
    }
    sockets.close();
    server.close();
    rmSync(directory, { recursive: true, force: true });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      resolve();
    });
  });

  const client = new CodexAppServerClient(`unix://${socketPath}`);
  await client.connect();
});

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

test("idle attached CLI turn delivery skips managed shell launch before app-server send", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  let ensureManagedShellCalls = 0;
  const requestCalls: Array<{ method: string; params?: JSONValue }> = [];

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "cli",
    status: "idle",
  });
  hooks.readThreadDeliverySnapshot = async () => ({
    hasTurnData: true,
    turnCount: 1,
    matchingUserTextCount: 0,
    updatedAt: 123_000,
    threadStatus: "idle",
    activeTurnId: null,
  });
  hooks.ensureManagedShellThread = async () => {
    ensureManagedShellCalls += 1;
    throw new Error("managed shell launch should not run for idle attached CLI delivery");
  };
  hooks.shouldStartViaAppServer = async () => true;
  hooks.shouldPreferCLIResumeFallback = async () => false;
  hooks.shouldPreferShellRelayFirst = async () => false;
  hooks.request = async (method: string, params?: JSONValue) => {
    requestCalls.push({ method, params });
    assert.equal(method, "turn/start");
    return {
      ok: true,
      mode: "steer",
      threadId: "thread-1",
    };
  };

  const result = await client.startTurn("thread-1", "keep parity", {
    deliveryMode: "steer",
  });

  assert.equal(ensureManagedShellCalls, 0);
  assert.deepEqual(requestCalls, [
    {
      method: "turn/start",
      params: {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "keep parity",
            text_elements: [],
          },
        ],
      },
    },
  ]);
  assert.deepEqual(result, {
    ok: true,
    mode: "steer",
    threadId: "thread-1",
  });
});

test("queued idle Codex desktop turn starts immediately instead of becoming an invisible follow-up", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  let enqueueCalls = 0;
  let startCalls = 0;

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "vscode",
    status: "idle",
  });
  hooks.readThreadDeliverySnapshot = async () => ({
    hasTurnData: true,
    turnCount: 2,
    matchingUserTextCount: 0,
    updatedAt: 123_000,
    threadStatus: "idle",
    activeTurnId: null,
  });
  hooks.enqueueTurnViaCodexDesktopIpc = async () => {
    enqueueCalls += 1;
    throw new Error("idle desktop sends should not queue a follow-up");
  };
  hooks.startTurnViaCodexDesktopIpc = async (threadId, text, options) => {
    startCalls += 1;
    assert.equal(threadId, "thread-1");
    assert.equal(text, "from mobile");
    assert.equal(options.deliveryMode, "queue");
    return {
      ok: true,
      mode: "codexDesktopIpcStart",
      threadId,
    };
  };

  const result = await client.startTurn("thread-1", "from mobile", {
    deliveryMode: "queue",
  });

  assert.equal(enqueueCalls, 0);
  assert.equal(startCalls, 1);
  assert.deepEqual(result, {
    ok: true,
    mode: "codexDesktopIpcStart",
    threadId: "thread-1",
  });
});

test("idle Codex desktop turn falls back to app-server when desktop IPC has no loaded client", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const requestCalls: Array<{ method: string; params?: JSONValue }> = [];

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "vscode",
    status: "idle",
  });
  hooks.readThreadDeliverySnapshot = async () => ({
    hasTurnData: true,
    turnCount: 2,
    matchingUserTextCount: 0,
    updatedAt: 123_000,
    threadStatus: "idle",
    activeTurnId: null,
  });
  hooks.startTurnViaCodexDesktopIpc = async () => {
    throw new Error("Codex Desktop IPC thread-follower-start-turn failed: no-client-found");
  };
  hooks.steerTurnViaCodexDesktopIpc = async () => {
    throw new Error("Codex Desktop IPC thread-follower-steer-turn failed: no-client-found");
  };
  hooks.enqueueTurnViaCodexDesktopIpc = async () => {
    throw new Error("idle desktop sends should not queue a follow-up");
  };
  hooks.request = async (method: string, params?: JSONValue) => {
    requestCalls.push({ method, params });
    assert.equal(method, "turn/start");
    return {
      ok: true,
    };
  };

  const result = await client.startTurn("thread-1", "from mobile", {
    deliveryMode: "steer",
  });

  assert.deepEqual(requestCalls, [
    {
      method: "turn/start",
      params: {
        threadId: "thread-1",
        input: [
          {
            type: "text",
            text: "from mobile",
            text_elements: [],
          },
        ],
      },
    },
  ]);
  assert.deepEqual(result, {
    ok: true,
    mode: "appServerStartAfterDesktopIpcNoClient",
    threadId: "thread-1",
  });
});

test("queued Codex desktop turn keeps queue mode when an image is attached", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  let queuedText: string | null = null;
  let startTurnCalls = 0;

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "vscode",
    status: "running",
  });
  hooks.readThreadDeliverySnapshot = async () => ({
    hasTurnData: true,
    turnCount: 3,
    matchingUserTextCount: 0,
    updatedAt: 123_000,
    threadStatus: "running",
    activeTurnId: "turn-3",
  });
  hooks.enqueueTurnViaCodexDesktopIpc = async (_threadId, text) => {
    queuedText = text;
    return {
      ok: true,
      mode: "codexDesktopIpcQueuedFollowUpBroadcast",
      threadId: "thread-1",
    };
  };
  hooks.startTurnViaCodexDesktopIpc = async () => {
    startTurnCalls += 1;
    throw new Error("queue with image must not start an immediate desktop turn");
  };

  const result = await client.startTurn("thread-1", "Use the screenshot", {
    deliveryMode: "queue",
    imageAttachments: [
      {
        path: "/tmp/helm-mobile/camera-roll-1.jpg",
        filename: "camera-roll-1.jpg",
        mimeType: "image/jpeg",
      },
    ],
  });

  assert.equal(startTurnCalls, 0);
  assert.match(queuedText ?? "", /Use the screenshot/);
  assert.match(queuedText ?? "", /camera-roll-1\.jpg/);
  assert.match(queuedText ?? "", /\/tmp\/helm-mobile\/camera-roll-1\.jpg/);
  assert.deepEqual(result, {
    ok: true,
    mode: "codexDesktopIpcQueuedFollowUpBroadcast",
    threadId: "thread-1",
  });
});

test("Codex desktop model update uses direct IPC for shared desktop threads", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  let ipcCall: { threadId: string; model: string; reasoningEffort: string | null } | null = null;

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "vscode",
    status: "idle",
  });
  hooks.setModelAndReasoningViaCodexDesktopIpc = async (threadId, model, reasoningEffort) => {
    ipcCall = { threadId, model, reasoningEffort };
    return { ok: true };
  };

  const result = await client.setModelAndReasoning("thread-1", " gpt-5.5 ", " high ");

  assert.deepEqual(ipcCall, {
    threadId: "thread-1",
    model: "gpt-5.5",
    reasoningEffort: "high",
  });
  assert.deepEqual(result, { ok: true });
});

test("Codex model update rejects non-shared desktop threads", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;

  hooks.loadThreadDeliverySummary = async () => ({
    sourceKind: "cli",
    status: "idle",
  });
  hooks.setModelAndReasoningViaCodexDesktopIpc = async () => {
    throw new Error("direct IPC should not run for CLI threads");
  };

  await assert.rejects(
    () => client.setModelAndReasoning("thread-1", "gpt-5.5", "high"),
    /shared Codex app session/
  );
});

test("Codex desktop queued follow-up append coalesces immediate duplicate messages", () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const message = (id: string, createdAt: number) => ({
    id,
    text: "queued from mobile",
    context: {
      prompt: "queued from mobile",
      addedFiles: [],
      fileAttachments: [],
      commentAttachments: [],
      ideContext: null,
      imageAttachments: [],
      workspaceRoots: ["/Users/devlin/GitHub/helm-dev"],
      collaborationMode: null,
    },
    cwd: "/Users/devlin/GitHub/helm-dev",
    createdAt,
  });

  const first = message("first", 1_000);
  const duplicate = message("duplicate", 1_500);
  const laterRepeat = message("later", 8_000);

  const afterDuplicate = hooks.codexDesktopQueuedFollowUpsWithAppendedMessage([first], duplicate);
  const afterLaterRepeat = hooks.codexDesktopQueuedFollowUpsWithAppendedMessage(afterDuplicate, laterRepeat);

  assert.deepEqual(afterDuplicate.map((entry) => entry.id), ["first"]);
  assert.deepEqual(afterLaterRepeat.map((entry) => entry.id), ["first", "later"]);
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

test("Codex desktop session reads prefer local rollout turns before oversized app-server payloads", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const requestCalls: Array<{ method: string; params?: JSONValue }> = [];

  hooks.localThreadReadFallback = async (threadId: string, includeTurns: boolean) => ({
    thread: {
      id: threadId,
      name: "Desktop thread",
      preview: "local rollout preview",
      cwd: "/tmp/project",
      status: "idle",
      updatedAt: 456_000,
      sourceKind: "vscode",
      ...(includeTurns
        ? {
            turns: [
              {
                id: "turn-1",
                status: "completed",
                items: [
                  {
                    id: "item-1",
                    type: "agentMessage",
                    text: "local rollout text",
                  },
                ],
              },
            ],
          }
        : {}),
    },
  });
  hooks.request = async (method: string, params?: JSONValue) => {
    requestCalls.push({ method, params });
    throw new Error("app-server thread/read should not be called");
  };

  const result = await client.readThread("thread-1", {
    allowTurnlessFallback: true,
  });
  const thread = result && typeof result === "object" && !Array.isArray(result)
    ? result.thread
    : null;

  assert.deepEqual(requestCalls, []);
  assert.equal(
    thread && typeof thread === "object" && !Array.isArray(thread)
      ? Array.isArray(thread.turns)
        ? thread.turns.length
        : 0
      : 0,
    1
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
    if (method === "thread/loaded/list") {
      return {
        data: [],
        nextCursor: null,
      } as JSONValue;
    }
    assert.equal(method, "thread/list");
    return {
      data: [
        {
          id: "thread-1",
          name: "Test app and fix bugs",
          preview: "Test app and fix bugs",
          cwd: "/tmp/project",
          projectName: "Codex Project",
          status: { type: "running" },
          updatedAt: 456_000,
          source: "vscode",
        },
        {
          id: "thread-2",
          name: "Daily bug scan",
          preview: "Daily bug scan",
          cwd: "/tmp/project",
          status: { type: "idle" },
          updatedAt: 455_000,
          source: "vscode",
        },
      ],
    } as JSONValue;
  };

  const threads = await hooks.listThreadsFromAppServer();

  assert.equal(threads[0]?.preview, "Waiting for output...");
  assert.equal(threads[0]?.projectName, "Codex Project");
  assert.equal(threads[1]?.preview, "No activity yet.");
  assert.equal(threads[0]?.sourceKind, "vscode");
});

test("Codex project names resolve from desktop workspace-root labels", () => {
  const previousPath = process.env.CODEX_GLOBAL_STATE_PATH;
  const folder = mkdtempSync(path.join(tmpdir(), "helm-codex-project-"));
  const statePath = path.join(folder, ".codex-global-state.json");
  process.env.CODEX_GLOBAL_STATE_PATH = statePath;
  writeFileSync(
    statePath,
    JSON.stringify({
      "electron-workspace-root-labels": {
        "/Users/devlin/Documents/New project": "Wedding",
      },
    }),
    "utf8"
  );

  try {
    assert.equal(codexProjectNameForPath("/Users/devlin/Documents/New project"), "Wedding");
  } finally {
    if (previousPath === undefined) {
      delete process.env.CODEX_GLOBAL_STATE_PATH;
    } else {
      process.env.CODEX_GLOBAL_STATE_PATH = previousPath;
    }
  }
});

test("recent title-only unknown app-server sessions stay idle", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const now = Date.now();

  hooks.request = async (method: string) => {
    if (method === "thread/loaded/list") {
      return {
        data: [],
        nextCursor: null,
      } as JSONValue;
    }
    return {
      data: [
        {
          id: "thread-1",
          name: "Resume Gabagool replay logic",
          preview: "Resume Gabagool replay logic",
          cwd: "/tmp/project",
          status: { type: "notLoaded" },
          updatedAt: now,
          source: "vscode",
        },
      ],
    } as JSONValue;
  };

  const threads = await hooks.listThreadsFromAppServer();

  assert.equal(threads[0]?.status, "idle");
  assert.equal(threads[0]?.preview, "No activity yet.");
  assert.equal(threads[0]?.sourceKind, "vscode");
});

test("loaded app-server sessions expose Codex Desktop controller metadata", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;
  const now = Date.now();

  hooks.request = async (method: string) => {
    switch (method) {
      case "thread/loaded/list":
        return {
          data: [{ id: "thread-1" }],
          nextCursor: null,
        } as JSONValue;
      case "thread/list":
        return {
          data: [
            {
              id: "thread-1",
              name: "Resume Gabagool replay logic",
              preview: "Resume Gabagool replay logic",
              cwd: "/tmp/project",
              status: { type: "idle" },
              updatedAt: now - 3_600_000,
              source: "vscode",
            },
            {
              id: "thread-2",
              name: "Update AGENTS.md",
              preview: "Update AGENTS.md",
              cwd: "/tmp/project",
              status: { type: "idle" },
              updatedAt: now - 3_600_000,
              source: "vscode",
            },
          ],
        } as JSONValue;
      default:
        throw new Error(`unexpected method: ${method}`);
    }
  };

  const threads = await hooks.listThreadsFromAppServer();

  assert.equal(threads[0]?.controller?.clientId, "codex-desktop");
  assert.equal(threads[0]?.controller?.clientName, "Codex Desktop");
  assert.equal(threads[1]?.controller, null);
});

test("active Codex workspace falls back to newest desktop thread when loaded list is empty", async () => {
  const client = new CodexAppServerClient("ws://127.0.0.1:0");
  const hooks = client as unknown as CodexClientPrivateHooks;

  hooks.readCodexDesktopActiveWorkspaceRoots = async () => [
    "/Users/devlin/GitHub/prediction-markets-bot",
  ];

  const threads = await hooks.applyCodexDesktopWorkspaceFocus([
    {
      id: "thread-1",
      cwd: "/Users/devlin/GitHub/helm-dev",
      workspacePath: "/Users/devlin/GitHub/helm-dev",
      updatedAt: 200,
      sourceKind: "vscode",
      controller: null,
    },
    {
      id: "thread-2",
      cwd: "/Users/devlin/GitHub/prediction-markets-bot",
      workspacePath: "/Users/devlin/GitHub/prediction-markets-bot",
      updatedAt: 150,
      sourceKind: "vscode",
      controller: null,
    },
    {
      id: "thread-3",
      cwd: "/Users/devlin/GitHub/prediction-markets-bot",
      workspacePath: "/Users/devlin/GitHub/prediction-markets-bot",
      updatedAt: 100,
      sourceKind: "vscode",
      controller: null,
    },
  ]);

  assert.equal(threads.find((thread) => thread.id === "thread-2")?.controller?.clientId, "codex-desktop");
  assert.equal(threads.find((thread) => thread.id === "thread-3")?.controller, null);
  assert.equal(threads.find((thread) => thread.id === "thread-1")?.controller, null);
});
