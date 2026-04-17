import type { ThreadController } from "./types.js";

const LEASE_TTL_MS = 10 * 60 * 1000;

type ClaimInput = {
  threadId: string;
  clientId: string;
  clientName: string;
  force?: boolean;
};

export class ThreadControllerRegistry {
  private readonly controllers = new Map<string, ThreadController>();

  get(threadId: string): ThreadController | null {
    this.pruneExpired(threadId);
    return this.controllers.get(threadId) ?? null;
  }

  list(): Map<string, ThreadController> {
    this.pruneAllExpired();
    return new Map(this.controllers);
  }

  claim(input: ClaimInput): ThreadController {
    this.pruneExpired(input.threadId);

    const now = Date.now();
    const existing = this.controllers.get(input.threadId);
    if (existing && existing.clientId !== input.clientId && !input.force) {
      throw new Error(
        `Thread is currently controlled by ${existing.clientName}. Release it first or take over explicitly.`
      );
    }

    const controller: ThreadController =
      existing && existing.clientId === input.clientId
        ? {
            ...existing,
            clientName: input.clientName,
            lastSeenAt: now,
          }
        : {
            clientId: input.clientId,
            clientName: input.clientName,
            claimedAt: now,
            lastSeenAt: now,
          };

    this.controllers.set(input.threadId, controller);
    return controller;
  }

  touch(threadId: string, clientId: string): ThreadController | null {
    this.pruneExpired(threadId);

    const existing = this.controllers.get(threadId);
    if (!existing || existing.clientId !== clientId) {
      return null;
    }

    const updated: ThreadController = {
      ...existing,
      lastSeenAt: Date.now(),
    };
    this.controllers.set(threadId, updated);
    return updated;
  }

  release(threadId: string, clientId: string, force = false): boolean {
    this.pruneExpired(threadId);

    const existing = this.controllers.get(threadId);
    if (!existing) {
      return false;
    }

    if (!force && existing.clientId !== clientId) {
      throw new Error(`Thread is currently controlled by ${existing.clientName}.`);
    }

    this.controllers.delete(threadId);
    return true;
  }

  remove(threadId: string): void {
    this.controllers.delete(threadId);
  }

  private pruneExpired(threadId: string): void {
    const existing = this.controllers.get(threadId);
    if (!existing) {
      return;
    }

    if (Date.now() - existing.lastSeenAt > LEASE_TTL_MS) {
      this.controllers.delete(threadId);
    }
  }

  private pruneAllExpired(): void {
    for (const threadId of this.controllers.keys()) {
      this.pruneExpired(threadId);
    }
  }
}
