import test from "node:test";
import assert from "node:assert/strict";
import { createHmac, randomBytes } from "node:crypto";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { PairingManager } from "./pairingManager.js";

function trustedSignature(
  key: string,
  method: string,
  path: string,
  timestamp: number,
  nonce: string,
  clientId: string
): string {
  return createHmac("sha256", Buffer.from(key, "base64url"))
    .update(method.toUpperCase())
    .update("\n")
    .update(path)
    .update("\n")
    .update(String(timestamp))
    .update("\n")
    .update(nonce)
    .update("\n")
    .update(clientId)
    .digest("base64url");
}

test("pairing bootstrap registers a trusted client from a valid pairing token", async () => {
  const dir = await mkdtemp(join(tmpdir(), "helm-pairing-"));
  const manager = new PairingManager(join(dir, "pairing.json"), null);
  const status = await manager.initialize();
  const clientKey = randomBytes(32).toString("base64url");

  const auth = manager.authenticate({
    token: status.token,
    method: "GET",
    path: "/api/pairing",
    clientId: "ios-device",
    clientName: "helm iPhone",
    clientKey,
    signature: null,
    timestamp: null,
    nonce: null,
  });

  assert.equal(auth.ok, true);
  assert.equal(auth.mode, "pairingToken");
  assert.equal(auth.bootstrappedTrust, true);
  assert.equal(auth.trustedClient?.id, "ios-device");
  assert.equal(manager.describe(false).trustedClients.length, 1);
  assert.equal(typeof manager.describe(false).bridgeId, "string");
});

test("trusted client signatures authenticate without resending the pairing token", async () => {
  const dir = await mkdtemp(join(tmpdir(), "helm-pairing-"));
  const manager = new PairingManager(join(dir, "pairing.json"), null);
  const status = await manager.initialize();
  const clientKey = randomBytes(32).toString("base64url");
  const clientId = "ipad-device";

  manager.authenticate({
    token: status.token,
    method: "GET",
    path: "/api/pairing",
    clientId,
    clientName: "helm iPad",
    clientKey,
    signature: null,
    timestamp: null,
    nonce: null,
  });

  const timestamp = Date.now();
  const nonce = "nonce-1";
  const signature = trustedSignature(clientKey, "GET", "/api/threads", timestamp, nonce, clientId);

  const auth = manager.authenticate({
    token: null,
    method: "GET",
    path: "/api/threads",
    clientId,
    clientName: "helm iPad",
    clientKey: null,
    signature,
    timestamp,
    nonce,
  });

  assert.equal(auth.ok, true);
  assert.equal(auth.mode, "trusted");
  assert.equal(auth.bootstrappedTrust, false);
  assert.equal(auth.trustedClient?.id, clientId);
});

test("trusted client nonces reject simple replay of a signed request", async () => {
  const dir = await mkdtemp(join(tmpdir(), "helm-pairing-"));
  const manager = new PairingManager(join(dir, "pairing.json"), null);
  const status = await manager.initialize();
  const clientKey = randomBytes(32).toString("base64url");
  const clientId = "replay-device";
  const timestamp = Date.now();
  const nonce = "replay-once";

  manager.authenticate({
    token: status.token,
    method: "GET",
    path: "/api/pairing",
    clientId,
    clientName: "helm replay client",
    clientKey,
    signature: null,
    timestamp: null,
    nonce: null,
  });

  const signature = trustedSignature(clientKey, "GET", "/api/runtime", timestamp, nonce, clientId);
  const first = manager.authenticate({
    token: null,
    method: "GET",
    path: "/api/runtime",
    clientId,
    clientName: "helm replay client",
    clientKey: null,
    signature,
    timestamp,
    nonce,
  });
  const second = manager.authenticate({
    token: null,
    method: "GET",
    path: "/api/runtime",
    clientId,
    clientName: "helm replay client",
    clientKey: null,
    signature,
    timestamp,
    nonce,
  });

  assert.equal(first.ok, true);
  assert.equal(second.ok, false);
});

test("legacy pairing files are normalized to include bridge identity and trusted-client storage", async () => {
  const dir = await mkdtemp(join(tmpdir(), "helm-pairing-"));
  const filePath = join(dir, "pairing.json");
  await writeFile(
    filePath,
    `${JSON.stringify({
      token: "legacy-token",
      createdAt: 1000,
      rotatedAt: 1000,
    })}\n`,
    "utf8"
  );

  const manager = new PairingManager(filePath, null);
  const status = await manager.initialize();

  assert.equal(status.token, "legacy-token");
  assert.equal(typeof status.bridgeId, "string");
  assert.deepEqual(status.trustedClients, []);
});
