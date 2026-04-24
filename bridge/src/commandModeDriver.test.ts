import test from "node:test";
import assert from "node:assert/strict";

import { buildCommandModeDriverSummary } from "./commandModeDriver.js";

test("command mode driver defaults to ChatGPT 5.5 label", () => {
  const summary = buildCommandModeDriverSummary({
    apiKey: "sk-test",
    model: "gpt-5.5",
  });

  assert.equal(summary.id, "openai-chatgpt");
  assert.equal(summary.label, "ChatGPT 5.5");
  assert.equal(summary.kind, "openai");
  assert.equal(summary.model, "gpt-5.5");
  assert.equal(summary.available, true);
});

test("command mode driver reports missing OpenAI key", () => {
  const summary = buildCommandModeDriverSummary({
    apiKey: "",
    model: "",
  });

  assert.equal(summary.model, "gpt-5.5");
  assert.equal(summary.available, false);
  assert.match(summary.availabilityDetail ?? "", /OPENAI_API_KEY/);
});
