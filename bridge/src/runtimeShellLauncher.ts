import { execFile, spawn } from "node:child_process";
import { accessSync, constants, existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const moduleDir = path.dirname(fileURLToPath(import.meta.url));

export type ManagedRuntime = "codex" | "claude" | "grok";

function wrapperName(runtime: ManagedRuntime): string {
  switch (runtime) {
    case "codex":
      return "helm-codex";
    case "claude":
      return "helm-claude";
    case "grok":
      return "helm-grok";
  }
}

export function defaultHelmRuntimeWrapperPath(runtime: ManagedRuntime): string {
  return path.join(homedir(), ".local", "bin", wrapperName(runtime));
}

function defaultHelmRuntimeShimPath(runtime: ManagedRuntime): string {
  return path.join(homedir(), ".local", "share", "helm", "runtime-shims", runtime);
}

function runtimeCaptureFilePath(): string {
  return path.join(homedir(), ".config", "helm", "runtime-binary-capture.json");
}

function runtimeLaunchRegistryPath(): string {
  return path.join(homedir(), ".config", "helm", "runtime-launches");
}

function runtimeRelayScriptPath(): string {
  return path.join(moduleDir, "..", "..", "scripts", "helm_runtime_relay.py");
}

function explicitRuntimePath(runtime: ManagedRuntime): string | undefined {
  switch (runtime) {
    case "codex":
      return process.env.HELM_REAL_CODEX_PATH?.trim();
    case "claude":
      return process.env.HELM_REAL_CLAUDE_PATH?.trim();
    case "grok":
      return process.env.HELM_REAL_GROK_PATH?.trim();
  }
}

function explicitWrapperPath(runtime: ManagedRuntime): string | undefined {
  switch (runtime) {
    case "codex":
      return process.env.HELM_CODEX_WRAPPER_PATH?.trim();
    case "claude":
      return process.env.HELM_CLAUDE_WRAPPER_PATH?.trim();
    case "grok":
      return process.env.HELM_GROK_WRAPPER_PATH?.trim();
  }
}

function runtimeCommandCandidates(runtime: ManagedRuntime): string[] {
  switch (runtime) {
    case "grok":
      return ["grok", "grok-cli"];
    case "codex":
    case "claude":
      return [runtime];
  }
}

export function hasHelmRuntimeWrapper(runtime: ManagedRuntime): boolean {
  return existsSync(defaultHelmRuntimeWrapperPath(runtime));
}

export async function resolveHelmRuntimeWrapperPath(runtime: ManagedRuntime): Promise<string> {
  const explicitPath = explicitWrapperPath(runtime);
  if (explicitPath) {
    return explicitPath;
  }

  try {
    const { stdout } = await execFileAsync("/bin/zsh", ["-lc", `command -v ${wrapperName(runtime)}`], {
      maxBuffer: 1024 * 1024,
    });
    const discoveredPath = stdout.trim();
    if (discoveredPath.length > 0) {
      return discoveredPath;
    }
  } catch {
    // Fall back to the standard local install location.
  }

  return defaultHelmRuntimeWrapperPath(runtime);
}

export function resolveUnderlyingRuntimeBinary(runtime: ManagedRuntime): string {
  const explicitPath = explicitRuntimePath(runtime);
  if (explicitPath && isUsableUnderlyingRuntimePath(runtime, explicitPath)) {
    return explicitPath;
  }

  const capturePath = process.env.HELM_RUNTIME_CAPTURE_FILE?.trim() || runtimeCaptureFilePath();
  if (existsSync(capturePath)) {
    try {
      const capture = JSON.parse(readFileSync(capturePath, "utf8")) as Record<
        string,
        { realPath?: string }
      >;
      const capturedPath = capture[runtime]?.realPath?.trim();
      if (capturedPath && isUsableUnderlyingRuntimePath(runtime, capturedPath)) {
        return capturedPath;
      }
    } catch {
      // Ignore malformed capture metadata and keep resolving.
    }
  }

  const shimDir = path.dirname(defaultHelmRuntimeShimPath(runtime));
  const entries = (process.env.PATH ?? "")
    .split(":")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0 && path.resolve(entry) !== path.resolve(shimDir));

  for (const entry of entries) {
    for (const command of runtimeCommandCandidates(runtime)) {
      const candidate = path.join(entry, command);
      if (isUsableUnderlyingRuntimePath(runtime, candidate)) {
        return candidate;
      }
    }
  }

  const [fallback] = runtimeCommandCandidates(runtime);
  return fallback ?? runtime;
}

export async function launchManagedRuntimeDetached(input: {
  runtime: ManagedRuntime;
  cwd: string;
  args: string[];
  env?: NodeJS.ProcessEnv;
}): Promise<void> {
  const wrapperPath = await resolveHelmRuntimeWrapperPath(input.runtime);
  const child = spawn(wrapperPath, input.args, {
    cwd: input.cwd,
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      HELM_DISABLE_AUTO_BRIDGE: "1",
      ...input.env,
    },
  });

  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve());
    child.once("error", (spawnError) => reject(spawnError));
  });
  child.unref();
}

export async function launchManagedCommandDetached(input: {
  runtime: string;
  cwd: string;
  command: string;
  args: string[];
  env?: NodeJS.ProcessEnv;
  threadId?: string | null;
  wrapperName?: string;
}): Promise<void> {
  const relayArgs = [
    runtimeRelayScriptPath(),
    "--registry-dir",
    runtimeLaunchRegistryPath(),
    "--runtime",
    input.runtime,
    "--wrapper",
    input.wrapperName ?? "helm-bridge",
    "--cwd",
    input.cwd,
  ];
  if (input.threadId?.trim()) {
    relayArgs.push("--thread-id", input.threadId.trim());
  }
  relayArgs.push("--", input.command, ...input.args);

  const child = spawn("python3", relayArgs, {
    cwd: input.cwd,
    detached: true,
    stdio: "ignore",
    env: {
      ...process.env,
      HELM_DISABLE_AUTO_BRIDGE: "1",
      ...input.env,
    },
  });

  await new Promise<void>((resolve, reject) => {
    child.once("spawn", () => resolve());
    child.once("error", (spawnError) => reject(spawnError));
  });
  child.unref();
}

function isUsableUnderlyingRuntimePath(runtime: ManagedRuntime, candidate: string): boolean {
  if (!existsSync(candidate)) {
    return false;
  }

  try {
    accessSync(candidate, constants.X_OK);
  } catch {
    return false;
  }

  const realCandidate = safeRealPath(candidate);
  if (!realCandidate) {
    return false;
  }

  const ignoredPaths = new Set(
    [
      path.join(moduleDir, "..", "..", "scripts", "helm-runtime-shim.sh"),
      path.join(moduleDir, "..", "..", "scripts", "helm-runtime-wrapper.sh"),
      defaultHelmRuntimeShimPath(runtime),
      defaultHelmRuntimeWrapperPath(runtime),
    ]
      .map((entry) => safeRealPath(entry))
      .filter((entry): entry is string => Boolean(entry))
  );

  return !ignoredPaths.has(realCandidate);
}

function safeRealPath(candidate: string): string | null {
  try {
    return realpathSync(candidate);
  } catch {
    return null;
  }
}
