import type { PendingApproval, RuntimeActivityEvent, RuntimePhase, RuntimeThreadState } from "./types.js";

const MAX_EVENTS_PER_THREAD = 20;
const MAX_RUNTIME_DETAIL_CHARS = 3000;
const MAX_APPROVAL_DETAIL_CHARS = 3000;
const STALE_RUNNING_EVENT_GRACE_MS = 2 * 60 * 1000;

type EventInput = Omit<RuntimeActivityEvent, "id" | "createdAt"> & {
  createdAt?: number;
};

export class RuntimeTracker {
  private readonly threads = new Map<string, RuntimeThreadState>();

  list(): RuntimeThreadState[] {
    return Array.from(this.threads.keys())
      .map((threadId) => this.reconciledState(threadId))
      .filter((state): state is RuntimeThreadState => state !== null)
      .map((state) => this.sanitizeThreadState(state))
      .sort((a, b) => b.lastUpdatedAt - a.lastUpdatedAt);
  }

  get(threadId: string): RuntimeThreadState | null {
    const state = this.reconciledState(threadId);
    return state ? this.sanitizeThreadState(state) : null;
  }

  recordEvent(input: EventInput): RuntimeThreadState {
    const now = input.createdAt ?? Date.now();
    const event = this.sanitizeRuntimeEvent({
      id: `${now}-${Math.random().toString(36).slice(2, 8)}`,
      createdAt: now,
      ...input,
    });

    const existing = this.getOrCreate(event.threadId);
    const pendingApprovals = existing.pendingApprovals.map((approval) => this.sanitizeApproval(approval));
    const phase = pendingApprovals.length > 0 ? "waitingApproval" : event.phase;

    const next: RuntimeThreadState = {
      ...existing,
      phase,
      currentTurnId: event.turnId ?? existing.currentTurnId,
      title: event.title,
      detail: event.detail,
      lastUpdatedAt: now,
      recentEvents: [event, ...existing.recentEvents]
        .map((existingEvent) => this.sanitizeRuntimeEvent(existingEvent))
        .slice(0, MAX_EVENTS_PER_THREAD),
      pendingApprovals,
    };

    if (event.phase === "completed") {
      next.currentTurnId = null;
    }

    this.threads.set(event.threadId, next);
    return next;
  }

  addApproval(approval: PendingApproval): RuntimeThreadState {
    const existing = this.getOrCreate(approval.threadId);
    const normalizedApproval = this.sanitizeApproval(approval);
    const filtered = existing.pendingApprovals.filter((item) => item.requestId !== approval.requestId);
    const pendingApprovals = [normalizedApproval, ...filtered.map((item) => this.sanitizeApproval(item))];

    const next: RuntimeThreadState = {
      ...existing,
      phase: "waitingApproval",
      currentTurnId: normalizedApproval.turnId ?? existing.currentTurnId,
      title: normalizedApproval.title,
      detail: normalizedApproval.detail,
      lastUpdatedAt: normalizedApproval.requestedAt,
      pendingApprovals,
    };

    this.threads.set(normalizedApproval.threadId, next);
    return next;
  }

  resolveApproval(requestId: string, decision: string): RuntimeThreadState | null {
    for (const [threadId, state] of this.threads) {
      const approval = state.pendingApprovals.find((item) => item.requestId === requestId);
      if (!approval) {
        continue;
      }

      const pendingApprovals = state.pendingApprovals.filter((item) => item.requestId !== requestId);
      const phase: RuntimePhase = pendingApprovals.length > 0 ? "waitingApproval" : decision === "accept" || decision === "acceptForSession" ? "running" : decision === "cancel" ? "blocked" : "idle";
      const next: RuntimeThreadState = {
        ...state,
        phase,
        title: `Approval ${decision}`,
        detail: this.trimDetail(approval.title, MAX_APPROVAL_DETAIL_CHARS),
        lastUpdatedAt: Date.now(),
        pendingApprovals: pendingApprovals.map((item) => this.sanitizeApproval(item)),
      };

      this.threads.set(threadId, next);
      return next;
    }

    return null;
  }

  remove(threadId: string): void {
    this.threads.delete(threadId);
  }

  syncManagedPresence(threads: Array<{
    threadId: string;
    lastUpdatedAt: number;
    title: string;
    detail: string | null;
  }>): void {
    const liveThreadIDs = new Set(threads.map((thread) => thread.threadId));

    for (const thread of threads) {
      const existing = this.threads.get(thread.threadId);
      if (existing) {
        this.threads.set(thread.threadId, {
          ...existing,
          lastUpdatedAt: Math.max(existing.lastUpdatedAt, thread.lastUpdatedAt),
          title: existing.title ?? thread.title,
          detail: this.trimDetail(existing.detail ?? thread.detail),
        });
        continue;
      }

      this.threads.set(thread.threadId, {
        threadId: thread.threadId,
        phase: "unknown",
        currentTurnId: null,
        title: thread.title,
        detail: this.trimDetail(thread.detail),
        lastUpdatedAt: thread.lastUpdatedAt,
        pendingApprovals: [],
        recentEvents: [],
      });
    }

    for (const [threadId, state] of this.threads.entries()) {
      if (liveThreadIDs.has(threadId)) {
        continue;
      }

      const placeholderOnly =
        state.phase === "unknown"
        && state.pendingApprovals.length === 0
        && state.recentEvents.length === 0;

      if (placeholderOnly) {
        this.threads.delete(threadId);
      }
    }
  }

  private getOrCreate(threadId: string): RuntimeThreadState {
    const existing = this.threads.get(threadId);
    if (existing) {
      return existing;
    }

    const fresh: RuntimeThreadState = {
      threadId,
      phase: "unknown",
      currentTurnId: null,
      title: null,
      detail: null,
      lastUpdatedAt: Date.now(),
      pendingApprovals: [],
      recentEvents: [],
    };

    this.threads.set(threadId, fresh);
    return fresh;
  }

  private reconciledState(threadId: string): RuntimeThreadState | null {
    const state = this.threads.get(threadId);
    if (!state) {
      return null;
    }

    const reconciled = this.reconcileStaleRunningPhase(state);
    if (reconciled !== state) {
      this.threads.set(threadId, reconciled);
    }
    return reconciled;
  }

  private reconcileStaleRunningPhase(state: RuntimeThreadState): RuntimeThreadState {
    if (state.phase !== "running") {
      return state;
    }

    const hasCurrentTurn = typeof state.currentTurnId === "string" && state.currentTurnId.trim().length > 0;
    if (hasCurrentTurn || state.pendingApprovals.length > 0) {
      return state;
    }

    const hasFreshRecentEvent =
      state.recentEvents.length > 0
      && Date.now() - state.lastUpdatedAt <= STALE_RUNNING_EVENT_GRACE_MS;
    if (hasFreshRecentEvent) {
      return state;
    }

    return {
      ...state,
      phase: "idle",
    };
  }

  private sanitizeThreadState(state: RuntimeThreadState): RuntimeThreadState {
    return {
      ...state,
      detail: this.trimDetail(state.detail),
      pendingApprovals: state.pendingApprovals.map((approval) => this.sanitizeApproval(approval)),
      recentEvents: state.recentEvents.map((event) => this.sanitizeRuntimeEvent(event)),
    };
  }

  private sanitizeRuntimeEvent(event: RuntimeActivityEvent): RuntimeActivityEvent {
    return {
      ...event,
      detail: this.trimDetail(event.detail),
    };
  }

  private sanitizeApproval(approval: PendingApproval): PendingApproval {
    return {
      ...approval,
      detail: this.trimDetail(approval.detail, MAX_APPROVAL_DETAIL_CHARS),
    };
  }

  private trimDetail(detail: string | null, maxChars = MAX_RUNTIME_DETAIL_CHARS): string | null {
    if (detail === null || detail.length <= maxChars) {
      return detail;
    }

    return detail.slice(0, maxChars);
  }
}
