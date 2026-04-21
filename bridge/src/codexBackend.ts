import { AgentBackend, type StartThreadInput } from "./agentBackend.js";
import { createDefaultCodexTransport, type CodexTransport } from "./codexTransport.js";
import type { JSONRPCId, JSONValue, StartTurnOptions, ThreadSummary } from "./types.js";

export class CodexBackend extends AgentBackend {
  private readonly transport: CodexTransport;

  constructor(endpoint: string, transport: CodexTransport = createDefaultCodexTransport(endpoint)) {
    super({
      id: "codex",
      label: "Codex",
      kind: "codex",
      description: "Codex via codex app-server on the Mac.",
      isDefault: true,
      available: true,
      availabilityDetail: "Ready when codex app-server is running on the Mac bridge host.",
      capabilities: {
        threadListing: true,
        threadCreation: true,
        turnExecution: true,
        turnInterrupt: true,
        approvals: true,
        planMode: false,
        voiceCommand: true,
        realtimeVoice: true,
        hooksAndSkillsParity: true,
        sharedThreadHandoff: true,
      },
      command: {
        routing: "threadTurns",
        approvals: "bridgeDecisions",
        handoff: "sharedThread",
        voiceInput: "bridgeRealtime",
        voiceOutput: "bridgeSpeech",
        supportsCommandFollowups: true,
        notes:
          "Command routes into shared Codex threads on the Mac. Approvals resolve through the helm bridge. Voice currently uses bridge-mediated Realtime input and bridge speech output.",
      },
    });

    this.transport = transport;
    this.transport.on("event", (event) => {
      this.emitConversationEvent(event);
    });
    this.transport.on("serverRequest", (request) => {
      this.emitServerRequest(request);
    });
  }

  async connect(): Promise<void> {
    await this.transport.connect();
  }

  async listThreads(): Promise<ThreadSummary[]> {
    const threads = await this.transport.listThreads();
    return threads.map((thread) => ({
      ...thread,
      backendId: this.summary.id,
      backendLabel: this.summary.label,
      backendKind: this.summary.kind,
    }));
  }

  async startThread(input: StartThreadInput = {}): Promise<JSONValue | undefined> {
    if (input.launchMode === "managedShell") {
      return await this.transport.startManagedShellThread(input);
    }
    return await this.transport.startThread(input);
  }

  async bootstrapManagedShellThread(input: StartThreadInput = {}): Promise<{
    threadId: string;
    cwd: string;
    mode: string;
  }> {
    return await this.transport.bootstrapManagedShellThread(input);
  }

  async ensureManagedShellThread(
    threadId: string,
    options: {
      launchManagedShell?: boolean;
      preferVisibleLaunch?: boolean;
    } = {}
  ): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
    cwd: string;
  }> {
    return await this.transport.ensureManagedShellThread(threadId, options);
  }

  async readThread(threadId: string): Promise<JSONValue | undefined> {
    return await this.transport.readThread(threadId, {
      allowTurnlessFallback: true,
    });
  }

  async startTurn(
    threadId: string,
    text: string,
    options: StartTurnOptions = {}
  ): Promise<JSONValue | undefined> {
    return await this.transport.startTurn(threadId, text, options);
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    return await this.transport.interruptTurn(threadId);
  }

  async sendInput(threadId: string, input: string): Promise<JSONValue | undefined> {
    return await this.transport.sendInput(threadId, input);
  }

  async renameThread(threadId: string, name: string): Promise<JSONValue | undefined> {
    return await this.transport.renameThread(threadId, name);
  }

  async archiveThread(threadId: string): Promise<void> {
    await this.transport.archiveThread(threadId);
  }

  respond(id: JSONRPCId, result: JSONValue): void {
    this.transport.respond(id, result);
  }
}
