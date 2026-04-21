import { CodexAppServerClient } from "./codexAppServerClient.js";
import type {
  ConversationEvent,
  JSONValue,
  ServerRequestEvent,
  StartTurnOptions,
  ThreadSummary,
} from "./types.js";

export interface CodexTransport {
  connect(): Promise<void>;
  listThreads(): Promise<ThreadSummary[]>;
  startThread(input?: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
    launchMode?: "sharedThread" | "managedShell";
    reasoningEffort?: string;
    codexFastMode?: boolean;
  }): Promise<JSONValue | undefined>;
  startManagedShellThread(input?: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
    launchMode?: "sharedThread" | "managedShell";
    reasoningEffort?: string;
    codexFastMode?: boolean;
  }): Promise<JSONValue | undefined>;
  bootstrapManagedShellThread(input?: {
    cwd?: string;
    model?: string;
    baseInstructions?: string;
    launchMode?: "sharedThread" | "managedShell";
    reasoningEffort?: string;
    codexFastMode?: boolean;
  }): Promise<{
    threadId: string;
    cwd: string;
    mode: string;
  }>;
  ensureManagedShellThread(
    threadId: string,
    options?: {
      launchManagedShell?: boolean;
      preferVisibleLaunch?: boolean;
    }
  ): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
    cwd: string;
  }>;
  readThread(
    threadId: string,
    options?: {
      includeTurns?: boolean;
      allowTurnlessFallback?: boolean;
    }
  ): Promise<JSONValue | undefined>;
  startTurn(
    threadId: string,
    text: string,
    options?: StartTurnOptions
  ): Promise<JSONValue | undefined>;
  interruptTurn(threadId: string): Promise<JSONValue | undefined>;
  sendInput(threadId: string, input: string): Promise<JSONValue | undefined>;
  renameThread(threadId: string, name: string): Promise<JSONValue | undefined>;
  archiveThread(threadId: string): Promise<void>;
  respond(id: string | number, result: JSONValue): void;
  on(event: "event", listener: (event: ConversationEvent) => void): this;
  on(event: "serverRequest", listener: (request: ServerRequestEvent) => void): this;
}

export class CodexAppServerTransport implements CodexTransport {
  private readonly client: CodexAppServerClient;

  constructor(endpoint: string) {
    this.client = new CodexAppServerClient(endpoint);
  }

  on(event: "event", listener: (event: ConversationEvent) => void): this;
  on(event: "serverRequest", listener: (request: ServerRequestEvent) => void): this;
  on(
    event: "event" | "serverRequest",
    listener: ((event: ConversationEvent) => void) | ((request: ServerRequestEvent) => void)
  ): this {
    this.client.on(event, listener);
    return this;
  }

  async connect(): Promise<void> {
    await this.client.connect();
  }

  async listThreads(): Promise<ThreadSummary[]> {
    return await this.client.listThreads();
  }

  async startThread(input = {}): Promise<JSONValue | undefined> {
    return await this.client.startThread(input);
  }

  async startManagedShellThread(input = {}): Promise<JSONValue | undefined> {
    return await this.client.startManagedShellThread(input);
  }

  async bootstrapManagedShellThread(input = {}): Promise<{
    threadId: string;
    cwd: string;
    mode: string;
  }> {
    return await this.client.bootstrapManagedShellThread(input);
  }

  async ensureManagedShellThread(
    threadId: string,
    options = {}
  ): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
    cwd: string;
  }> {
    return await this.client.ensureManagedShellThread(threadId, options);
  }

  async readThread(
    threadId: string,
    options: {
      includeTurns?: boolean;
      allowTurnlessFallback?: boolean;
    } = {}
  ): Promise<JSONValue | undefined> {
    return await this.client.readThread(threadId, options);
  }

  async startTurn(
    threadId: string,
    text: string,
    options: StartTurnOptions = {}
  ): Promise<JSONValue | undefined> {
    return await this.client.startTurn(threadId, text, options);
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    return await this.client.interruptTurn(threadId);
  }

  async sendInput(threadId: string, input: string): Promise<JSONValue | undefined> {
    return await this.client.sendInput(threadId, input);
  }

  async renameThread(threadId: string, name: string): Promise<JSONValue | undefined> {
    return await this.client.renameThread(threadId, name);
  }

  async archiveThread(threadId: string): Promise<void> {
    await this.client.archiveThread(threadId);
  }

  respond(id: string | number, result: JSONValue): void {
    this.client.respond(id, result);
  }
}

export function createDefaultCodexTransport(endpoint: string): CodexTransport {
  return new CodexAppServerTransport(endpoint);
}
