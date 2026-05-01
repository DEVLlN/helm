import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export type BridgeInstallMethod = "npm" | "homebrew" | "git" | "unknown";

export interface BridgePackageInfo {
  name: string;
  version: string;
}

export interface BridgeUpdateCommand {
  command: string;
  args: string[];
}

export interface BridgeUpdateCheckResult {
  status: "disabled" | "current" | "started" | "skipped";
  reason?: string;
  currentVersion?: string;
  latestVersion?: string;
  installMethod?: BridgeInstallMethod;
  updateURL?: string;
  updateCommand?: string;
}

export interface BridgeUpdateCheckOptions {
  rootDir: string;
  env?: NodeJS.ProcessEnv | Record<string, string | undefined>;
  packageInfo?: BridgePackageInfo | null;
  hasGitDir?: boolean;
  installMethod?: BridgeInstallMethod;
  fetchLatestVersion?: (packageName: string) => Promise<string | null>;
  runUpdate?: (command: string, args: string[]) => void;
  scriptExists?: (path: string) => boolean;
  logger?: Pick<Console, "log" | "warn">;
}

export interface BridgeUpdateStatus {
  status: "disabled" | "current" | "available" | "skipped";
  reason?: string;
  currentVersion?: string;
  latestVersion?: string;
  installMethod?: BridgeInstallMethod;
  updateURL?: string;
  updateCommand?: string;
}

export interface StartBridgeAutoUpdaterOptions extends BridgeUpdateCheckOptions {
  setTimeoutFn?: typeof setTimeout;
  setIntervalFn?: typeof setInterval;
}

export interface BridgeAutoUpdaterHandle {
  stop(): void;
  checkNow(): Promise<BridgeUpdateCheckResult>;
}

const PUBLIC_PACKAGE_NAME = "@devlln/helm";
const DEFAULT_INITIAL_DELAY_MS = 30_000;
const DEFAULT_INTERVAL_MS = 6 * 60 * 60 * 1000;

function versionSegments(version: string): number[] {
  const core = version.trim().replace(/^v/i, "").split("-", 1)[0] ?? "";
  const rawSegments = core.split(".").slice(0, 3);
  const segments = rawSegments.map((segment) => {
    const value = Number.parseInt(segment, 10);
    return Number.isFinite(value) ? value : 0;
  });

  while (segments.length < 3) {
    segments.push(0);
  }

  return segments;
}

export function compareSemver(lhs: string, rhs: string): number {
  const lhsSegments = versionSegments(lhs);
  const rhsSegments = versionSegments(rhs);

  for (let index = 0; index < 3; index += 1) {
    const lhsValue = lhsSegments[index] ?? 0;
    const rhsValue = rhsSegments[index] ?? 0;
    if (lhsValue < rhsValue) {
      return -1;
    }
    if (lhsValue > rhsValue) {
      return 1;
    }
  }

  return 0;
}

export function detectBridgeInstallMethod(input: {
  rootDir: string;
  packageName?: string | null;
  hasGitDir?: boolean;
}): BridgeInstallMethod {
  if (/\/Cellar\/helm\/[^/]+\/libexec\/?$/.test(input.rootDir) || input.rootDir.includes("/Cellar/helm/")) {
    return "homebrew";
  }

  if (input.hasGitDir) {
    return "git";
  }

  if (input.packageName === PUBLIC_PACKAGE_NAME || input.packageName === "@devlin/helm") {
    return "npm";
  }

  return "unknown";
}

export function shouldEnableBridgeAutoUpdate(input: {
  env: NodeJS.ProcessEnv | Record<string, string | undefined>;
  installMethod: BridgeInstallMethod;
  packageName?: string | null;
}): boolean {
  const override = input.env.HELM_BRIDGE_AUTO_UPDATE?.trim().toLowerCase();
  if (override === "0" || override === "false" || override === "off" || override === "no") {
    return false;
  }
  if (override === "1" || override === "true" || override === "on" || override === "yes") {
    return true;
  }

  return input.packageName === PUBLIC_PACKAGE_NAME
    && (input.installMethod === "npm" || input.installMethod === "homebrew");
}

export function buildBridgeUpdateCommand(input: {
  rootDir: string;
  installMethod: BridgeInstallMethod;
}): BridgeUpdateCommand {
  return {
    command: join(input.rootDir, "scripts", "helm-update.sh"),
    args: ["--yes", "--source", "bridge-auto", "--method", input.installMethod],
  };
}

function updateCommandForDisplay(installMethod: BridgeInstallMethod): string {
  switch (installMethod) {
    case "homebrew":
      return "brew update && brew upgrade devlln/helm/helm";
    case "npm":
      return "npm install -g @devlln/helm@latest";
    case "git":
      return "git pull && npm --prefix bridge install";
    case "unknown":
    default:
      return "helm update";
  }
}

function updateURLForVersion(version: string | undefined): string | undefined {
  if (!version) {
    return undefined;
  }

  return `https://www.npmjs.com/package/${PUBLIC_PACKAGE_NAME}/v/${version}`;
}

function readPackageInfo(rootDir: string): BridgePackageInfo | null {
  try {
    const parsed = JSON.parse(readFileSync(join(rootDir, "package.json"), "utf8")) as {
      name?: unknown;
      version?: unknown;
    };
    if (typeof parsed.name !== "string" || typeof parsed.version !== "string") {
      return null;
    }
    return { name: parsed.name, version: parsed.version };
  } catch {
    return null;
  }
}

async function fetchNpmLatestVersion(packageName: string): Promise<string | null> {
  const encodedName = encodeURIComponent(packageName).replace(/^%40/, "@");
  const response = await fetch(`https://registry.npmjs.org/${encodedName}/latest`, {
    headers: {
      accept: "application/json",
    },
  });

  if (!response.ok) {
    return null;
  }

  const body = await response.json() as { version?: unknown };
  return typeof body.version === "string" ? body.version : null;
}

function runDetachedUpdate(command: string, args: string[]): void {
  const child = spawn(command, args, {
    detached: true,
    stdio: "ignore",
    env: process.env,
  });
  child.unref();
}

export async function checkForBridgeUpdate(options: BridgeUpdateCheckOptions): Promise<BridgeUpdateCheckResult> {
  const status = await getBridgeUpdateStatus(options);
  switch (status.status) {
    case "disabled":
    case "current":
    case "skipped":
      return {
        ...status,
        status: status.status,
      };
    case "available":
      break;
  }

  const installMethod = status.installMethod ?? "unknown";
  const updateCommand = buildBridgeUpdateCommand({ rootDir: options.rootDir, installMethod });
  const runUpdate = options.runUpdate ?? runDetachedUpdate;
  runUpdate(updateCommand.command, updateCommand.args);
  options.logger?.log(
    `[bridge] Helm ${status.currentVersion ?? "<unknown>"} is older than ${status.latestVersion ?? "<unknown>"}; started ${installMethod} update.`
  );

  return {
    status: "started",
    currentVersion: status.currentVersion,
    latestVersion: status.latestVersion,
    installMethod,
    updateURL: status.updateURL,
    updateCommand: status.updateCommand,
  };
}

export async function getBridgeUpdateStatus(options: BridgeUpdateCheckOptions): Promise<BridgeUpdateStatus> {
  const env = options.env ?? process.env;
  const packageInfo = options.packageInfo ?? readPackageInfo(options.rootDir);
  if (!packageInfo) {
    return { status: "disabled", reason: "package-info-unavailable" };
  }

  const hasGitDir = options.hasGitDir ?? existsSync(join(options.rootDir, ".git"));
  const installMethod = options.installMethod ?? detectBridgeInstallMethod({
    rootDir: options.rootDir,
    packageName: packageInfo.name,
    hasGitDir,
  });

  if (!shouldEnableBridgeAutoUpdate({ env, installMethod, packageName: packageInfo.name })) {
    return {
      status: "disabled",
      reason: "auto-update-disabled",
      currentVersion: packageInfo.version,
      installMethod,
      updateCommand: updateCommandForDisplay(installMethod),
    };
  }

  const updateCommand = buildBridgeUpdateCommand({ rootDir: options.rootDir, installMethod });
  const scriptExists = options.scriptExists ?? existsSync;
  if (!scriptExists(updateCommand.command)) {
    return {
      status: "disabled",
      reason: "update-script-missing",
      currentVersion: packageInfo.version,
      installMethod,
      updateCommand: updateCommandForDisplay(installMethod),
    };
  }

  const fetchLatestVersion = options.fetchLatestVersion ?? fetchNpmLatestVersion;
  let latestVersion: string | null = null;
  try {
    latestVersion = await fetchLatestVersion(PUBLIC_PACKAGE_NAME);
  } catch (error) {
    options.logger?.warn(`[bridge] Helm auto-update check failed: ${error instanceof Error ? error.message : String(error)}`);
    return {
      status: "skipped",
      reason: "latest-version-fetch-failed",
      currentVersion: packageInfo.version,
      installMethod,
      updateCommand: updateCommandForDisplay(installMethod),
    };
  }

  if (!latestVersion) {
    return {
      status: "skipped",
      reason: "latest-version-unavailable",
      currentVersion: packageInfo.version,
      installMethod,
      updateCommand: updateCommandForDisplay(installMethod),
    };
  }

  if (compareSemver(packageInfo.version, latestVersion) >= 0) {
    return {
      status: "current",
      currentVersion: packageInfo.version,
      latestVersion,
      installMethod,
      updateURL: updateURLForVersion(latestVersion),
      updateCommand: updateCommandForDisplay(installMethod),
    };
  }

  return {
    status: "available",
    currentVersion: packageInfo.version,
    latestVersion,
    installMethod,
    updateURL: updateURLForVersion(latestVersion),
    updateCommand: updateCommandForDisplay(installMethod),
  };
}

function numberFromEnv(
  env: NodeJS.ProcessEnv | Record<string, string | undefined>,
  key: string,
  fallback: number
): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === "") {
    return fallback;
  }

  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

export function startBridgeAutoUpdater(options: StartBridgeAutoUpdaterOptions): BridgeAutoUpdaterHandle {
  const env = options.env ?? process.env;
  let stopped = false;
  let running = false;
  let timeoutHandle: ReturnType<typeof setTimeout> | null = null;
  let intervalHandle: ReturnType<typeof setInterval> | null = null;
  const setTimeoutFn = options.setTimeoutFn ?? setTimeout;
  const setIntervalFn = options.setIntervalFn ?? setInterval;

  const checkNow = async (): Promise<BridgeUpdateCheckResult> => {
    if (stopped || running) {
      return { status: "skipped", reason: stopped ? "stopped" : "already-running" };
    }

    running = true;
    try {
      return await checkForBridgeUpdate(options);
    } finally {
      running = false;
    }
  };

  const initialDelayMS = numberFromEnv(env, "HELM_BRIDGE_AUTO_UPDATE_INITIAL_DELAY_MS", DEFAULT_INITIAL_DELAY_MS);
  const intervalMS = numberFromEnv(env, "HELM_BRIDGE_AUTO_UPDATE_INTERVAL_MS", DEFAULT_INTERVAL_MS);

  timeoutHandle = setTimeoutFn(() => {
    void checkNow();
  }, initialDelayMS);
  timeoutHandle.unref?.();

  if (intervalMS > 0) {
    intervalHandle = setIntervalFn(() => {
      void checkNow();
    }, intervalMS);
    intervalHandle.unref?.();
  }

  return {
    stop() {
      stopped = true;
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      if (intervalHandle) {
        clearInterval(intervalHandle);
      }
    },
    checkNow,
  };
}
