#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = dirname(dirname(fileURLToPath(import.meta.url)));
const packageJSON = JSON.parse(readFileSync(join(rootDir, "package.json"), "utf8"));
const [, , command, ...rawArgs] = process.argv;

function usage() {
  console.log(`Helm CLI ${packageJSON.version}

Usage:
  helm setup [setup options]
  helm bridge <setup|up|pair|status|down> [options]
  helm platforms [--json]
  helm help [bridge]

Commands:
  setup      Install Helm bridge helpers, enable runtime wrapping, configure Tailscale, start the bridge, and print pairing details.
  bridge     Manage the local Helm bridge runtime and pairing helpers.
  platforms  Detect the local runtimes, shell integration, and Tailscale state that Helm can use.

Compatibility aliases:
  helm install  -> helm setup
  helm up       -> helm bridge up
  helm pair     -> helm bridge pair
  helm status   -> helm bridge status
  helm down     -> helm bridge down

Examples:
  helm setup
  helm setup --skip-tailscale --no-pairing-qr
  helm bridge up
  helm bridge pair --no-start
  helm platforms
  helm platforms --json
`);
}

function bridgeUsage() {
  console.log(`Helm bridge commands

Usage:
  helm bridge setup [setup options]
  helm bridge up [--lan]
  helm bridge pair [--no-start]
  helm bridge status
  helm bridge down

Bridge commands:
  setup   Run the guided Helm bridge setup flow.
  up      Start the local bridge and Codex app-server helper.
  pair    Start the bridge if needed, then print the pairing QR and setup link.
  status  Show bridge health, pairing details, and voice-provider availability.
  down    Stop the local prototype bridge stack.
`);
}

function runScript(script, args) {
  const result = spawnSync(join(rootDir, "scripts", script), args, {
    stdio: "inherit",
    env: process.env,
  });

  if (result.error) {
    console.error(`[helm] ${result.error.message}`);
    process.exit(1);
  }

  process.exit(result.status ?? 1);
}

function runSetup(args) {
  const passThrough = [];

  for (const arg of args) {
    if (arg === "--bridge" || arg === "--cli" || arg === "--bridge-only" || arg === "--cli-only") {
      continue;
    }

    if (arg === "--mac-app" || arg === "--with-mac-app" || arg === "--all" || arg === "--no-mac-app") {
      continue;
    }

    passThrough.push(arg);
  }

  runScript("install-helm.sh", passThrough);
}

function runPlatforms(args) {
  runScript("detect-helm-platforms.sh", args);
}

function runBridge(args) {
  const [subcommand, ...bridgeArgs] = args;

  switch (subcommand) {
    case undefined:
    case "help":
    case "--help":
    case "-h":
      bridgeUsage();
      return;
    case "setup":
      runSetup(bridgeArgs);
      return;
    case "up":
    case "start":
      runScript("prototype-up.sh", bridgeArgs);
      return;
    case "pair":
    case "qr":
      runScript("print-pairing-qr.sh", bridgeArgs);
      return;
    case "status":
      runScript("prototype-status.sh", bridgeArgs);
      return;
    case "down":
    case "stop":
      runScript("prototype-down.sh", bridgeArgs);
      return;
    default:
      console.error(`[helm] Unknown bridge command: ${subcommand}`);
      bridgeUsage();
      process.exit(2);
  }
}

switch (command) {
  case undefined:
  case "help":
  case "--help":
  case "-h":
    if (rawArgs[0] === "bridge") {
      bridgeUsage();
    } else {
      usage();
    }
    break;
  case "--version":
  case "-V":
  case "version":
    console.log(packageJSON.version);
    break;
  case "setup":
  case "install":
    runSetup(rawArgs);
    break;
  case "bridge":
    runBridge(rawArgs);
    break;
  case "platforms":
  case "doctor":
    runPlatforms(rawArgs);
    break;
  case "up":
  case "start":
    runScript("prototype-up.sh", rawArgs);
    break;
  case "pair":
  case "qr":
    runScript("print-pairing-qr.sh", rawArgs);
    break;
  case "status":
    runScript("prototype-status.sh", rawArgs);
    break;
  case "down":
  case "stop":
    runScript("prototype-down.sh", rawArgs);
    break;
  default:
    console.error(`[helm] Unknown command: ${command}`);
    usage();
    process.exit(2);
}
