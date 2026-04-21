import test from "node:test";
import assert from "node:assert/strict";

import { RealtimeEventLog } from "./realtimeEventLog.js";

test("realtime event log replays buffered events after the requested sequence", () => {
  const log = new RealtimeEventLog();
  log.publish({
    type: "helm.runtime.thread",
    payload: {
      thread: {
        threadId: "thread-1",
      },
    },
  });
  const second = log.publish({
    type: "helm.thread.detail",
    payload: {
      thread: {
        id: "thread-1",
      },
    },
  });

  const resume = log.describeResume(1);

  assert.equal(resume.canResume, true);
  assert.equal(resume.latestSequence, 2);
  assert.equal(resume.events.length, 1);
  assert.equal(resume.events[0]?.sequence, second.sequence);
});

test("realtime event log rejects resume requests that fell out of the replay window", () => {
  const log = new RealtimeEventLog();

  for (let index = 0; index < 450; index += 1) {
    log.publish({
      type: "helm.runtime.thread",
      payload: {
        thread: {
          threadId: `thread-${index}`,
          phase: "running",
        },
      },
    });
  }

  const resume = log.describeResume(10);

  assert.equal(resume.canResume, false);
  assert.equal(resume.events.length, 0);
  assert.equal(resume.latestSequence, 450);
  assert.equal(resume.oldestRetainedSequence > 10, true);
});
