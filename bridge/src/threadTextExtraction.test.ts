import test from "node:test";
import assert from "node:assert/strict";

import { extractReadableText } from "./threadTextExtraction.js";

test("extractReadableText flattens structured assistant text instead of taking the first string only", () => {
  const value = [
    {
      type: "output_text",
      text: "It worked this time.\n\nBuilt a fresh signed device app:",
    },
    {
      type: "output_text",
      text: "- Helm.app timestamp: Apr 16 19:45:13 2026",
    },
    {
      type: "output_text",
      text: "- Bundle id: com.devlin.helm",
    },
    {
      type: "output_text",
      text: "Installed and launched on The Phone.",
    },
  ];

  assert.equal(
    extractReadableText(value),
    [
      "It worked this time.\n\nBuilt a fresh signed device app:",
      "- Helm.app timestamp: Apr 16 19:45:13 2026",
      "- Bundle id: com.devlin.helm",
      "Installed and launched on The Phone.",
    ].join("\n")
  );
});

test("extractReadableText prefers human text fields and skips metadata-only keys", () => {
  const value = {
    type: "message",
    phase: "completed",
    content: [
      {
        type: "paragraph",
        text: "First paragraph.",
      },
      {
        type: "bullet",
        text: "- second item",
      },
    ],
  };

  assert.equal(
    extractReadableText(value),
    "First paragraph.\n- second item"
  );
});
