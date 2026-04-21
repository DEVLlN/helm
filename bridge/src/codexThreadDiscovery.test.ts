import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  codexThreadPreviewForDisplay,
  parseCodexRolloutTurns,
  preferredCodexThreadName,
  readCodexRolloutTailText,
} from "./codexThreadDiscovery.js";

function rolloutLine(payload: Record<string, unknown>): string {
  return JSON.stringify({
    type: "event_msg",
    payload,
  });
}

test("local rollout fallback preserves the tail of long agent messages", () => {
  const prefix = "AGENT-START ";
  const suffix = " AGENT-LATEST-TEXT";
  const message = `${prefix}${"middle ".repeat(12_000)}${suffix}`;
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({ type: "agent_message", turn_id: "turn-1", message, phase: "final_answer" }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as { items?: Array<{ text?: string }> } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.text?.endsWith(suffix), true);
  assert.equal(item?.text?.includes(prefix), false);
});

test("local rollout fallback preserves the tail of long command output", () => {
  const prefix = "OUTPUT-START ";
  const suffix = " OUTPUT-LATEST-TEXT";
  const output = `${prefix}${"stdout ".repeat(12_000)}${suffix}`;
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "exec_command_end",
        turn_id: "turn-1",
        command: "npm test",
        status: "completed",
        exit_code: 0,
        aggregated_output: output,
      }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as { items?: Array<{ aggregatedOutput?: string }> } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.aggregatedOutput?.endsWith(suffix), true);
  assert.equal(item?.aggregatedOutput?.includes(prefix), false);
});

test("local rollout fallback emits viewed image tool calls", () => {
  const imagePath = "/Users/devlin/.config/helm/mobile-attachments/dropped-image-1.jpg";
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "view_image_tool_call",
        turn_id: "turn-1",
        path: imagePath,
      }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as { items?: Array<{ type?: string; tool?: string; contentItems?: string }> } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.type, "dynamicToolCall");
  assert.equal(item?.tool, "Viewed Image");
  assert.equal(item?.contentItems, imagePath);
});

test("local rollout fallback emits called MCP tool calls", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "mcp_tool_call_end",
        turn_id: "turn-1",
        invocation: {
          server: "XcodeBuildMCP",
          tool: "session_show_defaults",
          arguments: {},
        },
        result: {
          Ok: {
            content: [
              {
                type: "text",
                text: "projectPath: ios/Helm.xcodeproj",
              },
            ],
          },
        },
      }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as { items?: Array<{ type?: string; tool?: string; contentItems?: string }> } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.type, "dynamicToolCall");
  assert.equal(item?.tool, "Called XcodeBuildMCP.session_show_defaults({})");
  assert.equal(item?.contentItems, "projectPath: ios/Helm.xcodeproj");
});

test("local rollout fallback orders turns by most recent activity", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "agent_message", message: "pre-task commentary" }),
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "exec_command_end",
        turn_id: "turn-1",
        command: "git status --short",
        status: "completed",
        exit_code: 0,
        aggregated_output: "M ios/Sources/SessionsView.swift",
      }),
      rolloutLine({ type: "task_complete", turn_id: "turn-1" }),
      rolloutLine({ type: "agent_message", message: "final assistant message" }),
    ].join("\n"),
    "thread-1"
  ) as Array<{ id: string; items: Array<{ type?: string; text?: string; command?: string }> }>;

  assert.deepEqual(turns.map((turn) => turn.id), ["local-rollout-thread-1", "turn-1"]);
  assert.equal(turns[0]?.items.at(-1)?.type, "agentMessage");
  assert.equal(turns[0]?.items.at(-1)?.text, "final assistant message");
  assert.equal(turns[1]?.items[0]?.type, "commandExecution");
  assert.equal(turns[1]?.items[0]?.command, "git status --short");
});

test("preferredCodexThreadName ignores degraded Helm app titles", () => {
  assert.equal(
    preferredCodexThreadName("Helm iOS", "mobile app support for creating a thread in Codex App OR Codex ClI"),
    "mobile app support for creating a thread in Codex App OR Codex ClI"
  );
  assert.equal(
    preferredCodexThreadName("testing", "mobile app support for creating a thread in Codex App OR Codex ClI"),
    "testing"
  );
});

test("codexThreadPreviewForDisplay uses waiting placeholder for fresh title-only sessions", () => {
  const now = Date.now();
  assert.equal(
    codexThreadPreviewForDisplay("Test app and fix bugs", now),
    "Waiting for output..."
  );
  assert.equal(
    codexThreadPreviewForDisplay("Daily bug scan", now - (24 * 60 * 60 * 1000)),
    "No activity yet."
  );
  assert.equal(
    codexThreadPreviewForDisplay("Daily bug scan", now - (9 * 24 * 60 * 60 * 1000)),
    "Daily bug scan"
  );
  assert.equal(
    codexThreadPreviewForDisplay("Resume Gabagool replay logic", now, {
      preferRecentIdle: true,
    }),
    "No activity yet."
  );
});

test("local rollout tail reader keeps recent complete records", () => {
  const dir = mkdtempSync(path.join(tmpdir(), "helm-rollout-tail-"));
  const rolloutPath = path.join(dir, "rollout.jsonl");
  try {
    const oldLine = rolloutLine({ type: "agent_message", turn_id: "old", message: "old text" });
    const recentLine = rolloutLine({ type: "agent_message", turn_id: "recent", message: "recent text" });
    writeFileSync(
      rolloutPath,
      `${oldLine}\n${"x".repeat(200)}\n${recentLine}\n`,
      "utf8"
    );

    const text = readCodexRolloutTailText(rolloutPath, 128);
    assert.equal(text.includes("old text"), false);
    assert.equal(text.includes("recent text"), true);
    assert.equal(text, readFileSync(rolloutPath, "utf8").slice(-128).replace(/^[^\n]*\n/, ""));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
