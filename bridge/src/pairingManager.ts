import { createHmac, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

type TrustedClientRecord = {
  id: string;
  name: string;
  key: string;
  createdAt: number;
  lastSeenAt: number;
};

type TrustedClientStatus = Omit<TrustedClientRecord, "key">;

type PairingRecord = {
  token: string;
  bridgeId: string;
  trustedClients: TrustedClientRecord[];
  createdAt: number;
  rotatedAt: number;
};

type PairingStatus = {
  token: string;
  tokenHint: string;
  filePath: string;
  bridgeId: string;
  trustedClients: TrustedClientStatus[];
  createdAt: number;
  rotatedAt: number;
};

export type PairingAuthInput = {
  token: string | null | undefined;
  method: string;
  path: string;
  clientId: string | null | undefined;
  clientName: string | null | undefined;
  clientKey: string | null | undefined;
  signature: string | null | undefined;
  timestamp: number | null | undefined;
  nonce: string | null | undefined;
};

export type PairingAuthResult = {
  ok: boolean;
  mode: "trusted" | "pairingToken" | null;
  bridgeId: string;
  trustedClient: TrustedClientStatus | null;
  bootstrappedTrust: boolean;
};

export class PairingManager {
  private static readonly TRUST_SIGNATURE_WINDOW_MS = 5 * 60 * 1000;
  private static readonly MAX_RECENT_NONCES_PER_CLIENT = 64;

  private record: PairingRecord | null = null;
  private status: PairingStatus | null = null;
  private writeInFlight: Promise<void> | null = null;
  private readonly recentNonces = new Map<string, Map<string, number>>();

  constructor(
    private readonly filePath: string,
    private readonly envToken: string | null
  ) {}

  async initialize(): Promise<PairingStatus> {
    if (this.status && this.record) {
      return this.status;
    }

    if (this.envToken) {
      const now = Date.now();
      this.record = this.normalizeRecord({
        token: this.envToken,
        createdAt: now,
        rotatedAt: now,
      });
      this.status = this.buildStatus(this.record);
      return this.status;
    }

    const existing = await this.readFromDisk();
    if (existing) {
      const normalized = this.normalizeRecord(existing);
      this.record = normalized;
      this.status = this.buildStatus(normalized);
      if (this.recordNeedsPersistence(existing, normalized)) {
        this.schedulePersist();
      }
      return this.status;
    }

    const created = this.createRecord();
    this.record = created;
    this.status = this.buildStatus(created);
    await this.persistCurrentRecord();
    return this.status;
  }

  validate(candidate: string | null | undefined): boolean {
    if (!candidate?.trim() || !this.status) {
      return false;
    }

    const expected = Buffer.from(this.status.token);
    const actual = Buffer.from(candidate.trim());
    if (expected.length !== actual.length) {
      return false;
    }

    return timingSafeEqual(expected, actual);
  }

  authenticate(input: PairingAuthInput): PairingAuthResult {
    if (!this.record || !this.status) {
      throw new Error("Pairing manager not initialized");
    }

    const trustedClient = this.authenticateTrustedClient(input);
    if (trustedClient) {
      return {
        ok: true,
        mode: "trusted",
        bridgeId: this.record.bridgeId,
        trustedClient,
        bootstrappedTrust: false,
      };
    }

    if (!this.validate(input.token)) {
      return {
        ok: false,
        mode: null,
        bridgeId: this.record.bridgeId,
        trustedClient: null,
        bootstrappedTrust: false,
      };
    }

    const bootstrappedClient = this.bootstrapTrustedClient(input);
    return {
      ok: true,
      mode: "pairingToken",
      bridgeId: this.record.bridgeId,
      trustedClient: bootstrappedClient,
      bootstrappedTrust: bootstrappedClient !== null,
    };
  }

  describe(includeSecret: boolean): Omit<PairingStatus, "token"> & { token?: string } {
    if (!this.status) {
      throw new Error("Pairing manager not initialized");
    }

    return includeSecret
      ? { ...this.status }
      : {
          tokenHint: this.status.tokenHint,
          filePath: this.status.filePath,
          bridgeId: this.status.bridgeId,
          trustedClients: this.status.trustedClients,
          createdAt: this.status.createdAt,
          rotatedAt: this.status.rotatedAt,
        };
  }

  private authenticateTrustedClient(input: PairingAuthInput): TrustedClientStatus | null {
    if (!this.record || !this.status) {
      return null;
    }

    const clientId = input.clientId?.trim() ?? "";
    const signature = input.signature?.trim() ?? "";
    const nonce = input.nonce?.trim() ?? "";
    const timestamp =
      typeof input.timestamp === "number" && Number.isFinite(input.timestamp)
        ? input.timestamp
        : Number.NaN;

    if (!clientId || !signature || !nonce || !Number.isFinite(timestamp)) {
      return null;
    }

    const client = this.record.trustedClients.find((candidate) => candidate.id === clientId);
    if (!client) {
      return null;
    }

    const now = Date.now();
    if (Math.abs(now - timestamp) > PairingManager.TRUST_SIGNATURE_WINDOW_MS) {
      return null;
    }

    const keyBytes = this.decodeClientKey(client.key);
    if (!keyBytes) {
      return null;
    }

    const expectedSignature = this.signatureForTrustedRequest(
      keyBytes,
      input.method,
      input.path,
      timestamp,
      nonce,
      clientId
    );
    const expected = Buffer.from(expectedSignature);
    const actual = Buffer.from(signature);
    if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
      return null;
    }

    const nonces = this.recentNoncesForClient(clientId, now);
    if (nonces.has(nonce)) {
      return null;
    }
    nonces.set(nonce, now);
    this.trimRecentNonces(nonces);

    client.lastSeenAt = now;
    const nextName = input.clientName?.trim();
    if (nextName && nextName !== client.name) {
      client.name = nextName;
      this.schedulePersist();
    }
    this.status = this.buildStatus(this.record);
    return this.sanitizeTrustedClient(client);
  }

  private bootstrapTrustedClient(input: PairingAuthInput): TrustedClientStatus | null {
    if (!this.record) {
      return null;
    }

    const clientId = input.clientId?.trim() ?? "";
    const clientName = input.clientName?.trim() ?? "";
    const clientKey = input.clientKey?.trim() ?? "";
    const keyBytes = this.decodeClientKey(clientKey);

    if (!clientId || !clientName || !keyBytes) {
      return null;
    }

    const now = Date.now();
    const existing = this.record.trustedClients.find((candidate) => candidate.id === clientId);
    if (existing) {
      existing.name = clientName;
      existing.key = clientKey;
      existing.lastSeenAt = now;
      this.status = this.buildStatus(this.record);
      this.schedulePersist();
      return this.sanitizeTrustedClient(existing);
    }

    const created: TrustedClientRecord = {
      id: clientId,
      name: clientName,
      key: clientKey,
      createdAt: now,
      lastSeenAt: now,
    };
    this.record.trustedClients.push(created);
    this.status = this.buildStatus(this.record);
    this.schedulePersist();
    return this.sanitizeTrustedClient(created);
  }

  private recentNoncesForClient(clientId: string, now: number): Map<string, number> {
    const existing = this.recentNonces.get(clientId);
    if (existing) {
      for (const [nonce, timestamp] of existing.entries()) {
        if (now - timestamp > PairingManager.TRUST_SIGNATURE_WINDOW_MS) {
          existing.delete(nonce);
        }
      }
      return existing;
    }

    const created = new Map<string, number>();
    this.recentNonces.set(clientId, created);
    return created;
  }

  private trimRecentNonces(nonces: Map<string, number>): void {
    if (nonces.size <= PairingManager.MAX_RECENT_NONCES_PER_CLIENT) {
      return;
    }

    const ordered = [...nonces.entries()].sort((lhs, rhs) => lhs[1] - rhs[1]);
    while (ordered.length > PairingManager.MAX_RECENT_NONCES_PER_CLIENT) {
      const removed = ordered.shift();
      if (!removed) {
        break;
      }
      nonces.delete(removed[0]);
    }
  }

  private signatureForTrustedRequest(
    key: Buffer,
    method: string,
    path: string,
    timestamp: number,
    nonce: string,
    clientId: string
  ): string {
    return createHmac("sha256", key)
      .update(method.trim().toUpperCase())
      .update("\n")
      .update(path.trim())
      .update("\n")
      .update(String(Math.trunc(timestamp)))
      .update("\n")
      .update(nonce)
      .update("\n")
      .update(clientId)
      .digest("base64url");
  }

  private sanitizeTrustedClient(record: TrustedClientRecord): TrustedClientStatus {
    return {
      id: record.id,
      name: record.name,
      createdAt: record.createdAt,
      lastSeenAt: record.lastSeenAt,
    };
  }

  private decodeClientKey(value: string): Buffer | null {
    if (!value) {
      return null;
    }

    try {
      const decoded = Buffer.from(value, "base64url");
      return decoded.byteLength >= 24 ? decoded : null;
    } catch {
      return null;
    }
  }

  private async readFromDisk(): Promise<Partial<PairingRecord> | null> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<PairingRecord>;
      if (
        typeof parsed.token === "string" &&
        typeof parsed.createdAt === "number" &&
        typeof parsed.rotatedAt === "number"
      ) {
        return parsed;
      }
    } catch {
      return null;
    }

    return null;
  }

  private normalizeRecord(record: Partial<PairingRecord>): PairingRecord {
    const now = Date.now();
    return {
      token: typeof record.token === "string" ? record.token : randomBytes(24).toString("base64url"),
      bridgeId:
        typeof record.bridgeId === "string" && record.bridgeId.trim().length > 0
          ? record.bridgeId.trim()
          : randomUUID(),
      trustedClients: Array.isArray(record.trustedClients)
        ? record.trustedClients.flatMap((client) => {
            if (
              client &&
              typeof client.id === "string" &&
              typeof client.name === "string" &&
              typeof client.key === "string" &&
              typeof client.createdAt === "number" &&
              typeof client.lastSeenAt === "number"
            ) {
              return [{
                id: client.id,
                name: client.name,
                key: client.key,
                createdAt: client.createdAt,
                lastSeenAt: client.lastSeenAt,
              }];
            }
            return [];
          })
        : [],
      createdAt: typeof record.createdAt === "number" ? record.createdAt : now,
      rotatedAt: typeof record.rotatedAt === "number" ? record.rotatedAt : now,
    };
  }

  private recordNeedsPersistence(
    original: Partial<PairingRecord>,
    normalized: PairingRecord
  ): boolean {
    return original.bridgeId !== normalized.bridgeId
      || !Array.isArray(original.trustedClients)
      || original.trustedClients.length !== normalized.trustedClients.length;
  }

  private async writeToDisk(record: PairingRecord): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true });
    await writeFile(this.filePath, `${JSON.stringify(record, null, 2)}\n`, "utf8");
  }

  private createRecord(): PairingRecord {
    const now = Date.now();
    return {
      token: randomBytes(24).toString("base64url"),
      bridgeId: randomUUID(),
      trustedClients: [],
      createdAt: now,
      rotatedAt: now,
    };
  }

  private buildStatus(record: PairingRecord): PairingStatus {
    return {
      token: record.token,
      tokenHint: this.maskToken(record.token),
      filePath: this.filePath,
      bridgeId: record.bridgeId,
      trustedClients: record.trustedClients.map((client) => this.sanitizeTrustedClient(client)),
      createdAt: record.createdAt,
      rotatedAt: record.rotatedAt,
    };
  }

  private schedulePersist(): void {
    if (this.envToken) {
      return;
    }

    if (!this.writeInFlight) {
      this.writeInFlight = this.persistCurrentRecord()
        .catch((error) => {
          const message = error instanceof Error ? error.message : String(error);
          console.warn(`[bridge] failed to persist pairing state: ${message}`);
        })
        .finally(() => {
          this.writeInFlight = null;
        });
    }
  }

  private async persistCurrentRecord(): Promise<void> {
    if (!this.record || this.envToken) {
      return;
    }

    await this.writeToDisk(this.record);
  }

  private maskToken(token: string): string {
    if (token.length <= 8) {
      return token;
    }

    return `${token.slice(0, 4)}...${token.slice(-4)}`;
  }
}
