import { AgentBackend, type StartThreadInput } from "./agentBackend.js";
import type { BackendSummary, JSONRPCId, JSONValue, StartTurnOptions, ThreadSummary } from "./types.js";

export class UnavailableBackend extends AgentBackend {
  constructor(summary: BackendSummary) {
    super(summary);
  }

  async connect(): Promise<void> {
    return;
  }

  async listThreads(): Promise<ThreadSummary[]> {
    return [];
  }

  async startThread(_input: StartThreadInput = {}): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  async readThread(_threadId: string): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  async startTurn(_threadId: string, _text: string, _options: StartTurnOptions = {}): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  async interruptTurn(_threadId: string): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  async sendInput(_threadId: string, _input: string): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  async renameThread(_threadId: string, _name: string): Promise<JSONValue | undefined> {
    throw this.unavailableError();
  }

  respond(_id: JSONRPCId, _result: JSONValue): void {
    throw this.unavailableError();
  }

  private unavailableError(): Error {
    return new Error(this.summary.availabilityDetail ?? `${this.summary.label} is not available in this build`);
  }
}
