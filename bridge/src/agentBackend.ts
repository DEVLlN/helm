import EventEmitter from "node:events";

import type {
  BackendSummary,
  ConversationEvent,
  JSONRPCId,
  JSONValue,
  ServerRequestEvent,
  StartTurnOptions,
  ThreadSummary,
} from "./types.js";

export type StartThreadInput = {
  cwd?: string;
  model?: string;
  baseInstructions?: string;
  launchMode?: "sharedThread" | "managedShell";
  reasoningEffort?: string;
  codexFastMode?: boolean;
  claudeContextMode?: "normal" | "1m";
};

export abstract class AgentBackend extends EventEmitter {
  constructor(readonly summary: BackendSummary) {
    super();
  }

  abstract connect(): Promise<void>;
  abstract listThreads(): Promise<ThreadSummary[]>;
  abstract startThread(input?: StartThreadInput): Promise<JSONValue | undefined>;
  abstract readThread(threadId: string): Promise<JSONValue | undefined>;
  abstract startTurn(threadId: string, text: string, options?: StartTurnOptions): Promise<JSONValue | undefined>;
  abstract interruptTurn(threadId: string): Promise<JSONValue | undefined>;
  abstract sendInput(threadId: string, input: string): Promise<JSONValue | undefined>;
  abstract renameThread(threadId: string, name: string): Promise<JSONValue | undefined>;
  abstract respond(id: JSONRPCId, result: JSONValue): void;

  protected emitConversationEvent(event: ConversationEvent): void {
    this.emit("event", event);
  }

  protected emitServerRequest(request: ServerRequestEvent): void {
    this.emit("serverRequest", request);
  }
}
