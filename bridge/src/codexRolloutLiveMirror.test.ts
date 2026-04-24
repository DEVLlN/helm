import test from "node:test";
import assert from "node:assert/strict";

import {
  createCodexRolloutLiveMirrorController,
  isCodexRolloutMirrorEligibleSummary,
  type CodexRolloutMirrorChange,
} from "./codexRolloutLiveMirror.js";
import type { ThreadSummary } from "./types.js";

test("Codex rollout live mirror bootstraps and republishes when the rollout file advances", async () => {
  let fileStats = { size: 128, mtimeMs: 1_000 };
  const changes: CodexRolloutMirrorChange[] = [];
  const summary = codexSummary("thread-1");
  const mirror = createCodexRolloutLiveMirrorController({
    resolveRolloutPath: async (threadId) => `/tmp/${threadId}.jsonl`,
    statFile: async () => fileStats,
    onRolloutChanged: async (change) => {
      changes.push(change);
    },
    now: () => 10_000,
  });

  assert.equal(await mirror.observeThread(summary), true);
  assert.deepEqual(changes.map((change) => change.reason), ["bootstrap"]);
  assert.equal(changes[0]?.rolloutPath, "/tmp/thread-1.jsonl");

  await mirror.poll();
  assert.equal(changes.length, 1);

  fileStats = { size: 256, mtimeMs: 1_200 };
  await mirror.poll();
  assert.deepEqual(changes.map((change) => change.reason), ["bootstrap", "changed"]);
  assert.equal(changes[1]?.size, 256);
});

test("Codex rollout live mirror ignores non-Codex summaries and expires idle records", async () => {
  let currentTime = 1_000;
  const changes: CodexRolloutMirrorChange[] = [];
  const mirror = createCodexRolloutLiveMirrorController({
    resolveRolloutPath: async (threadId) => `/tmp/${threadId}.jsonl`,
    statFile: async () => ({ size: 10, mtimeMs: 10 }),
    onRolloutChanged: async (change) => {
      changes.push(change);
    },
    now: () => currentTime,
    idleTimeoutMs: 100,
  });

  assert.equal(await mirror.observeThread({
    ...codexSummary("thread-web"),
    backendId: "web",
    backendKind: "browser",
    sourceKind: "web",
  }), false);
  assert.deepEqual(mirror.activeThreadIds(), []);

  assert.equal(await mirror.observeThread(codexSummary("thread-1")), true);
  assert.deepEqual(mirror.activeThreadIds(), ["thread-1"]);

  currentTime = 1_200;
  await mirror.poll();
  assert.deepEqual(mirror.activeThreadIds(), []);
  assert.equal(changes.length, 1);
});

test("Codex rollout mirror eligibility includes Codex app and CLI-backed threads", () => {
  assert.equal(isCodexRolloutMirrorEligibleSummary(codexSummary("app")), true);
  assert.equal(isCodexRolloutMirrorEligibleSummary({
    ...codexSummary("cli"),
    backendId: "other",
    backendKind: "terminal",
    sourceKind: "cli",
  }), true);
  assert.equal(isCodexRolloutMirrorEligibleSummary({
    ...codexSummary("web"),
    backendId: "browser",
    backendKind: "browser",
    sourceKind: "web",
  }), false);
});

function codexSummary(id: string): ThreadSummary {
  return {
    id,
    name: "Codex thread",
    preview: "Working",
    cwd: "/tmp/project",
    workspacePath: "/tmp/project",
    status: "running",
    updatedAt: 1_000,
    sourceKind: "vscode",
    launchSource: null,
    backendId: "codex",
    backendLabel: "Codex",
    backendKind: "codex",
    controller: null,
  };
}
