import { BridgeServer } from "./bridgeServer.js";

async function main(): Promise<void> {
  const server = new BridgeServer();
  await server.start();
  console.log("[bridge] listening");
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.stack ?? error.message : String(error);
  console.error("[bridge] fatal error");
  console.error(message);
  process.exitCode = 1;
});

