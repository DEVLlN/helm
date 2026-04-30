import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { startBridgeAutoUpdater } from "./bridgeAutoUpdater.js";
import { BridgeServer } from "./bridgeServer.js";

async function main(): Promise<void> {
  const rootDir = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
  const server = new BridgeServer();
  await server.start();
  startBridgeAutoUpdater({ rootDir, logger: console });
  console.log("[bridge] listening");
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error("[bridge] fatal error");
  console.error(message);
  process.exitCode = 1;
});
