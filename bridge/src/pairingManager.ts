import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { randomBytes, timingSafeEqual } from "node:crypto";

type PairingRecord = {
  token: string;
  createdAt: number;
  rotatedAt: number;
};

type PairingStatus = {
  token: string;
  tokenHint: string;
  filePath: string;
  createdAt: number;
  rotatedAt: number;
};

export class PairingManager {
  private status: PairingStatus | null = null;

  constructor(
    private readonly filePath: string,
    private readonly envToken: string | null
  ) {}

  async initialize(): Promise<PairingStatus> {
    if (this.status) {
      return this.status;
    }

    if (this.envToken) {
      const now = Date.now();
      this.status = this.buildStatus({
        token: this.envToken,
        createdAt: now,
        rotatedAt: now,
      });
      return this.status;
    }

    const existing = await this.readFromDisk();
    if (existing) {
      this.status = this.buildStatus(existing);
      return this.status;
    }

    const created = await this.writeToDisk(this.createRecord());
    this.status = this.buildStatus(created);
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

  describe(includeSecret: boolean): Omit<PairingStatus, "token"> & { token?: string } {
    if (!this.status) {
      throw new Error("Pairing manager not initialized");
    }

    return includeSecret
      ? { ...this.status }
      : {
          tokenHint: this.status.tokenHint,
          filePath: this.status.filePath,
          createdAt: this.status.createdAt,
          rotatedAt: this.status.rotatedAt,
        };
  }

  private async readFromDisk(): Promise<PairingRecord | null> {
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<PairingRecord>;
      if (
        typeof parsed.token === "string" &&
        typeof parsed.createdAt === "number" &&
        typeof parsed.rotatedAt === "number"
      ) {
        return {
          token: parsed.token,
          createdAt: parsed.createdAt,
          rotatedAt: parsed.rotatedAt,
        };
      }
    } catch {
      return null;
    }

    return null;
  }

  private async writeToDisk(record: PairingRecord): Promise<PairingRecord> {
    await mkdir(dirname(this.filePath), { recursive: true });
    await writeFile(this.filePath, `${JSON.stringify(record, null, 2)}\n`, "utf8");
    return record;
  }

  private createRecord(): PairingRecord {
    const now = Date.now();
    return {
      token: randomBytes(24).toString("base64url"),
      createdAt: now,
      rotatedAt: now,
    };
  }

  private buildStatus(record: PairingRecord): PairingStatus {
    return {
      token: record.token,
      tokenHint: this.maskToken(record.token),
      filePath: this.filePath,
      createdAt: record.createdAt,
      rotatedAt: record.rotatedAt,
    };
  }

  private maskToken(token: string): string {
    if (token.length <= 8) {
      return token;
    }

    return `${token.slice(0, 4)}...${token.slice(-4)}`;
  }
}
