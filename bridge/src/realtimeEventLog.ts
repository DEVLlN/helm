type RealtimeEventRecord = {
  sequence: number;
  text: string;
  byteLength: number;
  createdAt: number;
};

export type RealtimeResumeState = {
  canResume: boolean;
  latestSequence: number;
  oldestRetainedSequence: number;
  events: RealtimeEventRecord[];
};

export class RealtimeEventLog {
  private static readonly MAX_EVENTS = 400;
  private static readonly MAX_BYTES = 6 * 1024 * 1024;

  private latestSequence = 0;
  private bufferedBytes = 0;
  private readonly events: RealtimeEventRecord[] = [];

  publish(payload: Record<string, unknown>): RealtimeEventRecord {
    const sequence = ++this.latestSequence;
    const envelope = {
      ...payload,
      sequence,
    };
    const text = JSON.stringify(envelope);
    const byteLength = Buffer.byteLength(text, "utf8");
    const record = {
      sequence,
      text,
      byteLength,
      createdAt: Date.now(),
    };
    this.events.push(record);
    this.bufferedBytes += byteLength;
    this.trim();
    return record;
  }

  describeResume(afterSequence: number | null | undefined): RealtimeResumeState {
    const oldestRetainedSequence =
      this.events[0]?.sequence ?? (this.latestSequence > 0 ? this.latestSequence + 1 : 1);
    const requested =
      typeof afterSequence === "number" && Number.isFinite(afterSequence)
        ? Math.max(0, Math.trunc(afterSequence))
        : null;
    const canResume =
      requested !== null
      && requested >= oldestRetainedSequence - 1
      && requested <= this.latestSequence;

    return {
      canResume,
      latestSequence: this.latestSequence,
      oldestRetainedSequence,
      events:
        canResume && requested !== null
          ? this.events.filter((record) => record.sequence > requested)
          : [],
    };
  }

  private trim(): void {
    while (
      this.events.length > RealtimeEventLog.MAX_EVENTS
      || this.bufferedBytes > RealtimeEventLog.MAX_BYTES
    ) {
      const removed = this.events.shift();
      if (!removed) {
        break;
      }
      this.bufferedBytes -= removed.byteLength;
    }
  }
}
