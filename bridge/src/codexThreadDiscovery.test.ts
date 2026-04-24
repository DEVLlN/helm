import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  codexThreadPreviewForDisplay,
  parseCodexRolloutUpdatedAt,
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

function responseLine(payload: Record<string, unknown>): string {
  return JSON.stringify({
    type: "response_item",
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

  const turn = turns[0] as {
    items?: Array<{
      type?: string;
      tool?: string;
      contentItems?: string;
      imageAttachments?: Array<{ path?: string; mimeType?: string; filename?: string }>;
    }>;
  } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.type, "dynamicToolCall");
  assert.equal(item?.tool, "Viewed Image");
  assert.equal(item?.contentItems, imagePath);
  assert.equal(item?.imageAttachments?.[0]?.path, imagePath);
  assert.equal(item?.imageAttachments?.[0]?.mimeType, "image/jpeg");
  assert.equal(item?.imageAttachments?.[0]?.filename, "dropped-image-1.jpg");
});

test("local rollout fallback emits generated image attachments", () => {
  const imagePath = "/Users/devlin/.codex/generated_images/thread-1/ig_result.png";
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "image_generation_end",
        turn_id: "turn-1",
        saved_path: imagePath,
        revised_prompt: "A Helm app icon.",
      }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as {
    items?: Array<{
      type?: string;
      tool?: string;
      contentItems?: string;
      imageAttachments?: Array<{ path?: string; mimeType?: string; filename?: string; source?: string }>;
    }>;
  } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.type, "dynamicToolCall");
  assert.equal(item?.tool, "Generated Image");
  assert.equal(item?.contentItems, imagePath);
  assert.equal(item?.imageAttachments?.[0]?.path, imagePath);
  assert.equal(item?.imageAttachments?.[0]?.mimeType, "image/png");
  assert.equal(item?.imageAttachments?.[0]?.filename, "ig_result.png");
  assert.equal(item?.imageAttachments?.[0]?.source, "image_generation");
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

test("local rollout fallback emits update plan task items", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      responseLine({
        type: "function_call",
        name: "update_plan",
        arguments: JSON.stringify({
          explanation: "Working through the visible task list.",
          plan: [
            { step: "Save parity plan", status: "completed" },
            { step: "Run replay coverage", status: "in_progress" },
            { step: "Verify final status", status: "pending" },
          ],
        }),
      }),
    ].join("\n"),
    "thread-1"
  );

  const turn = turns[0] as { items?: Array<{ type?: string; title?: string; text?: string; metadataSummary?: string }> } | undefined;
  const item = turn?.items?.[0];
  assert.equal(item?.type, "plan");
  assert.equal(item?.title, "1 out of 3 tasks completed");
  assert.equal(
    item?.text,
    [
      "1 out of 3 tasks completed",
      "✓ Save parity plan",
      "◉ Run replay coverage",
      "□ Verify final status",
    ].join("\n")
  );
  assert.equal(item?.metadataSummary, "Working through the visible task list.");
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

test("local rollout fallback emits assistant response item messages", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "exec_command_end",
        turn_id: "turn-1",
        command: "git status --short",
        status: "completed",
        exit_code: 0,
      }),
      responseLine({
        type: "message",
        content: [
          {
            type: "output_text",
            text: "final assistant response from response item",
          },
        ],
      }),
      rolloutLine({ type: "task_complete", turn_id: "turn-1" }),
    ].join("\n"),
    "thread-1"
  ) as Array<{ id: string; items: Array<{ type?: string; text?: string; command?: string }> }>;

  assert.equal(turns[0]?.id, "turn-1");
  assert.equal(turns[0]?.items.at(-1)?.type, "agentMessage");
  assert.equal(turns[0]?.items.at(-1)?.text, "final assistant response from response item");
});

test("local rollout fallback ignores response input messages", () => {
  const turns = parseCodexRolloutTurns(
    [
      responseLine({
        type: "message",
        content: [
          {
            type: "input_text",
            text: "<collaboration_mode>internal context</collaboration_mode>",
          },
        ],
      }),
      rolloutLine({ type: "user_message", message: "actual user text" }),
    ].join("\n"),
    "thread-1"
  ) as Array<{ items: Array<{ type?: string; content?: { text?: string } }> }>;

  assert.deepEqual(
    turns[0]?.items.map((item) => item.content?.text),
    ["actual user text"]
  );
});

test("local rollout fallback deduplicates paired event and response messages", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({ type: "task_started", turn_id: "turn-1" }),
      rolloutLine({
        type: "agent_message",
        turn_id: "turn-1",
        message: "same assistant response",
      }),
      responseLine({
        type: "message",
        content: [
          {
            type: "output_text",
            text: [
              "same assistant response",
              "",
              "<oai-mem-citation>",
              "<citation_entries>",
              "MEMORY.md:1-2|note=[context]",
              "</citation_entries>",
              "<rollout_ids>",
              "</rollout_ids>",
              "</oai-mem-citation>",
            ].join("\n"),
          },
        ],
      }),
      rolloutLine({ type: "task_complete", turn_id: "turn-1" }),
    ].join("\n"),
    "thread-1"
  ) as Array<{ id: string; items: Array<{ type?: string; text?: string }> }>;

  assert.deepEqual(
    turns[0]?.items.map((item) => item.text),
    ["same assistant response"]
  );
});

test("local rollout fallback attaches unscoped final answers to completed turn", () => {
  const turns = parseCodexRolloutTurns(
    [
      rolloutLine({
        type: "exec_command_end",
        turn_id: "turn-1",
        command: "npm test",
        status: "completed",
        aggregated_output: "tests passed",
      }),
      rolloutLine({
        type: "agent_message",
        message: "final answer text",
        phase: "final_answer",
      }),
      responseLine({
        type: "message",
        phase: "final_answer",
        content: [
          {
            type: "output_text",
            text: [
              "final answer text",
              "",
              "<oai-mem-citation>",
              "<citation_entries>",
              "MEMORY.md:1-2|note=[context]",
              "</citation_entries>",
              "<rollout_ids>",
              "</rollout_ids>",
              "</oai-mem-citation>",
            ].join("\n"),
          },
        ],
      }),
      rolloutLine({
        type: "task_complete",
        turn_id: "turn-1",
        last_agent_message: "final answer text",
      }),
    ].join("\n"),
    "thread-1"
  ) as Array<{ id: string; items: Array<{ type?: string; text?: string }> }>;

  assert.equal(turns.length, 1);
  assert.equal(turns[0]?.id, "turn-1");
  assert.deepEqual(
    turns[0]?.items
      .filter((item) => item.type === "agentMessage")
      .map((item) => item.text),
    ["final answer text"]
  );
});

test("local rollout fallback derives freshness from rollout timestamps", () => {
  assert.equal(
    parseCodexRolloutUpdatedAt(
      [
        JSON.stringify({
          timestamp: "2026-04-23T20:54:44.546Z",
          type: "event_msg",
          payload: { type: "task_started" },
        }),
        JSON.stringify({
          timestamp: "2026-04-23T20:57:20.200Z",
          type: "event_msg",
          payload: { type: "mcp_tool_call_end" },
        }),
      ].join("\n")
    ),
    Date.parse("2026-04-23T20:57:20.200Z")
  );
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
