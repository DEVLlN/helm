import assert from "node:assert/strict";
import test from "node:test";

import { RuntimeTracker } from "./runtimeTracker.js";

test("runtime tracker demotes stale running phases without an active turn", () => {
  const tracker = new RuntimeTracker();
  const staleStartedAt = Date.now() - (5 * 60 * 1000);

  tracker.recordEvent({
    threadId: "thread-1",
    turnId: null,
    itemId: null,
    method: "turn/started",
    title: "Turn started",
    detail: "thread-1",
    phase: "running",
    createdAt: staleStartedAt,
  });

  assert.equal(tracker.get("thread-1")?.phase, "idle");
  assert.equal(tracker.list()[0]?.phase, "idle");
});

test("runtime tracker keeps fresh running phases visible", () => {
  const tracker = new RuntimeTracker();
  const startedAt = Date.now();

  tracker.recordEvent({
    threadId: "thread-1",
    turnId: null,
    itemId: null,
    method: "turn/started",
    title: "Turn started",
    detail: "thread-1",
    phase: "running",
    createdAt: startedAt,
  });

  assert.equal(tracker.get("thread-1")?.phase, "running");
});

test("runtime tracker keeps stale running phases when a turn is still attached", () => {
  const tracker = new RuntimeTracker();
  const staleStartedAt = Date.now() - (5 * 60 * 1000);

  tracker.recordEvent({
    threadId: "thread-1",
    turnId: "turn-1",
    itemId: null,
    method: "turn/started",
    title: "Turn started",
    detail: "thread-1",
    phase: "running",
    createdAt: staleStartedAt,
  });

  assert.equal(tracker.get("thread-1")?.phase, "running");
  assert.equal(tracker.get("thread-1")?.currentTurnId, "turn-1");
});
