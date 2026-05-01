import test from "node:test";
import assert from "node:assert/strict";

import {
  buildBridgeUpdateCommand,
  checkForBridgeUpdate,
  compareSemver,
  detectBridgeInstallMethod,
  getBridgeUpdateStatus,
  shouldEnableBridgeAutoUpdate,
} from "./bridgeAutoUpdater.js";

test("compareSemver compares numeric version segments", () => {
  assert.equal(compareSemver("0.1.10", "0.2.0"), -1);
  assert.equal(compareSemver("0.2.0", "0.1.10"), 1);
  assert.equal(compareSemver("1.0.0", "1.0.0"), 0);
  assert.equal(compareSemver("1.0.0-beta.1", "1.0.0"), 0);
});

test("detectBridgeInstallMethod prefers Homebrew cellar installs and marks git checkouts as git", () => {
  assert.equal(
    detectBridgeInstallMethod({
      rootDir: "/opt/homebrew/Cellar/helm/0.2.0/libexec",
      packageName: "@devlln/helm",
      hasGitDir: false,
    }),
    "homebrew"
  );

  assert.equal(
    detectBridgeInstallMethod({
      rootDir: "/Users/devlin/GitHub/helm-dev",
      packageName: "@devlln/helm",
      hasGitDir: true,
    }),
    "git"
  );
});

test("shouldEnableBridgeAutoUpdate skips local checkouts unless forced", () => {
  assert.equal(
    shouldEnableBridgeAutoUpdate({
      env: {},
      installMethod: "git",
      packageName: "@devlln/helm",
    }),
    false
  );

  assert.equal(
    shouldEnableBridgeAutoUpdate({
      env: { HELM_BRIDGE_AUTO_UPDATE: "1" },
      installMethod: "git",
      packageName: "@devlln/helm",
    }),
    true
  );

  assert.equal(
    shouldEnableBridgeAutoUpdate({
      env: {},
      installMethod: "npm",
      packageName: "@devlln/helm",
    }),
    true
  );
});

test("buildBridgeUpdateCommand runs the packaged update script with the detected method", () => {
  assert.deepEqual(
    buildBridgeUpdateCommand({
      rootDir: "/opt/homebrew/Cellar/helm/0.2.0/libexec",
      installMethod: "homebrew",
    }),
    {
      command: "/opt/homebrew/Cellar/helm/0.2.0/libexec/scripts/helm-update.sh",
      args: ["--yes", "--source", "bridge-auto", "--method", "homebrew"],
    }
  );
});

test("checkForBridgeUpdate starts the updater when registry version is newer", async () => {
  const updates: Array<{ command: string; args: string[] }> = [];

  const result = await checkForBridgeUpdate({
    rootDir: "/usr/local/lib/node_modules/@devlln/helm",
    packageInfo: { name: "@devlln/helm", version: "0.1.10" },
    hasGitDir: false,
    env: {},
    fetchLatestVersion: async () => "0.2.0",
    runUpdate: (command, args) => {
      updates.push({ command, args });
    },
    scriptExists: () => true,
  });

  assert.equal(result.status, "started");
  assert.deepEqual(updates, [
    {
      command: "/usr/local/lib/node_modules/@devlln/helm/scripts/helm-update.sh",
      args: ["--yes", "--source", "bridge-auto", "--method", "npm"],
    },
  ]);
});

test("getBridgeUpdateStatus reports available updates with a user-facing link and command", async () => {
  const result = await getBridgeUpdateStatus({
    rootDir: "/opt/homebrew/Cellar/helm/0.2.0/libexec",
    packageInfo: { name: "@devlln/helm", version: "0.2.0" },
    hasGitDir: false,
    env: {},
    installMethod: "homebrew",
    fetchLatestVersion: async () => "0.2.1",
    scriptExists: () => true,
  });

  assert.equal(result.status, "available");
  assert.equal(result.currentVersion, "0.2.0");
  assert.equal(result.latestVersion, "0.2.1");
  assert.equal(result.updateURL, "https://www.npmjs.com/package/@devlln/helm/v/0.2.1");
  assert.equal(result.updateCommand, "brew update && brew upgrade devlln/helm/helm");
});
