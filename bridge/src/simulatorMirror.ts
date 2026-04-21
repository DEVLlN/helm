import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type BootedSimulator = {
  udid: string;
  name: string;
  runtime: string;
  state: "Booted";
};

export function parseBootedSimulators(output: string): BootedSimulator[] {
  const simulators: BootedSimulator[] = [];
  let currentRuntime = "";

  for (const line of output.split(/\r?\n/)) {
    const runtimeMatch = line.match(/^--\s+(.+?)\s+--$/);
    if (runtimeMatch) {
      currentRuntime = runtimeMatch[1]?.trim() ?? "";
      continue;
    }

    const deviceMatch = line.match(/^\s*(.+?)\s+\(([0-9A-F-]{36})\)\s+\((Booted)\)\s*$/i);
    if (!deviceMatch) {
      continue;
    }

    const [, name, udid, state] = deviceMatch;
    if (!name || !udid || state !== "Booted") {
      continue;
    }

    simulators.push({
      udid,
      name: name.trim(),
      runtime: currentRuntime,
      state: "Booted",
    });
  }

  return simulators;
}

export async function listBootedSimulators(): Promise<BootedSimulator[]> {
  const { stdout } = await execFileAsync(
    "xcrun",
    ["simctl", "list", "devices"],
    { maxBuffer: 1024 * 1024 }
  );
  return parseBootedSimulators(stdout);
}

export async function captureSimulatorScreenshot(udid: string): Promise<Buffer> {
  const tempDir = await mkdtemp(path.join(tmpdir(), "helm-sim-mirror-"));
  const screenshotPath = path.join(tempDir, "frame.png");

  try {
    await execFileAsync(
      "xcrun",
      ["simctl", "io", udid, "screenshot", "--type=png", screenshotPath],
      { maxBuffer: 1024 * 1024 }
    );
    return await readFile(screenshotPath);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}
