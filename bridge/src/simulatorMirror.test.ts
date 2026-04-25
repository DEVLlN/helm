import test from "node:test";
import assert from "node:assert/strict";

import {
  parseBootedSimulators,
  parseSimulatorAccessibilitySnapshot,
} from "./simulatorMirror.js";

test("parseBootedSimulators returns only booted devices with runtime labels", () => {
  const simulators = parseBootedSimulators(`
== Devices ==
-- iOS 26.4 --
    Helm iPhone 17 Pro (3CF9BB16-E74C-4FBA-901B-7A1C83EBAA6C) (Booted)
    iPhone 17 (11111111-2222-3333-4444-555555555555) (Shutdown)
-- watchOS 26.4 --
    Apple Watch Series 11 (46mm) (C85AA8B6-9B1F-4E85-ACF5-BFBD2FEF9B74) (Shutdown)
-- tvOS 26.4 --
    Apple TV 4K (01234567-89AB-CDEF-0123-456789ABCDEF) (Booted)
  `);

  assert.deepEqual(simulators, [
    {
      udid: "3CF9BB16-E74C-4FBA-901B-7A1C83EBAA6C",
      name: "Helm iPhone 17 Pro",
      runtime: "iOS 26.4",
      state: "Booted",
    },
    {
      udid: "01234567-89AB-CDEF-0123-456789ABCDEF",
      name: "Apple TV 4K",
      runtime: "tvOS 26.4",
      state: "Booted",
    },
  ]);
});

test("parseSimulatorAccessibilitySnapshot normalizes visible simulator elements", () => {
  const snapshot = parseSimulatorAccessibilitySnapshot([
    "AXGroup\t\tgroup\t100\t200\t400\t800",
    "AXButton\t\tCollapse task list\t120\t250\t80\t40",
    "AXStaticText\t\tPlan Gabagool22 parity\t180\t220\t220\t30",
    "AXButton\t\tOutside\t20\t20\t10\t10",
  ].join("\n"));

  assert.deepEqual(snapshot.screenFrame, {
    x: 100,
    y: 200,
    width: 400,
    height: 800,
  });
  const button = snapshot.elements.find((element) => element.description === "Collapse task list");
  assert.equal(snapshot.elements.length, 2);
  assert.deepEqual(button?.normalizedFrame, {
    x: 0.05,
    y: 0.0625,
    width: 0.2,
    height: 0.05,
  });
});

test("parseSimulatorAccessibilitySnapshot suppresses duplicate large action targets", () => {
  const taskLabel = "4 out of 7 tasks completed, " + "task ".repeat(30);
  const snapshot = parseSimulatorAccessibilitySnapshot([
    "AXGroup\t\tgroup\t100\t200\t400\t800",
    `AXButton\t\t${taskLabel}\t100\t200\t400\t200`,
    `AXButton\t\t${taskLabel}\t110\t450\t380\t180`,
    "AXButton\t\tSend to Codex\t450\t900\t40\t40",
    "AXButton\t\tSend to Codex\t450\t950\t40\t40",
  ].join("\n"));

  assert.equal(
    snapshot.elements.filter((element) => element.description === taskLabel.trim()).length,
    1
  );
  assert.equal(
    snapshot.elements.filter((element) => element.description === "Send to Codex").length,
    2
  );
});
