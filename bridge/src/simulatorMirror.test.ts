import test from "node:test";
import assert from "node:assert/strict";

import { parseBootedSimulators } from "./simulatorMirror.js";

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
