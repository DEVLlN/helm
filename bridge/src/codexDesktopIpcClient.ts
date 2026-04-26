import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

import type { JSONValue } from "./types.js";

const INITIALIZING_CLIENT_ID = "initializing-client";
const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const CONNECT_TIMEOUT_MS = 3_000;
const MAX_IPC_FRAME_BYTES = 256 * 1024 * 1024;

const REQUEST_VERSIONS = new Map<string, number>([
  ["thread-follower-start-turn", 1],
  ["thread-follower-steer-turn", 1],
  ["thread-follower-interrupt-turn", 1],
  ["thread-follower-set-model-and-reasoning", 1],
  ["thread-follower-set-queued-follow-ups-state", 1],
  ["thread-queued-followups-changed", 1],
]);

export type CodexDesktopUserInput =
  | {
      type: "text";
      text: string;
      text_elements: [];
    }
  | {
      type: "localImage";
      path: string;
    };

export type CodexDesktopQueuedFollowUp = {
  id: string;
  text: string;
  context: {
    prompt: string;
    addedFiles: JSONValue[];
    fileAttachments: JSONValue[];
    commentAttachments: JSONValue[];
    ideContext: JSONValue | null;
    imageAttachments: JSONValue[];
    workspaceRoots: string[];
    collaborationMode: JSONValue | null;
  };
  cwd: string | null;
  createdAt: number;
};

export type CodexDesktopQueuedFollowUpsState = Record<string, CodexDesktopQueuedFollowUp[]>;

type PendingResponse = {
  resolve: (message: CodexDesktopIpcResponseMessage) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
};

type CodexDesktopIpcResponseMessage = {
  type: "response";
  requestId: string;
  resultType: "success" | "error";
  method?: string;
  handledByClientId?: string;
  result?: JSONValue;
  error?: string;
};

type CodexDesktopIpcMessage =
  | CodexDesktopIpcResponseMessage
  | {
      type: "client-discovery-request";
      requestId: string;
      request?: {
        method?: string;
      };
    }
  | {
      type: "request";
      requestId: string;
      method?: string;
    }
  | {
      type: "broadcast";
      method?: string;
    };

export class CodexDesktopIpcRequestError extends Error {
  constructor(
    readonly method: string,
    readonly code: string
  ) {
    super(`Codex Desktop IPC ${method} failed: ${code}`);
    this.name = "CodexDesktopIpcRequestError";
  }
}

export function codexDesktopIpcSocketPath(): string {
  if (process.platform === "win32") {
    return path.join("\\\\.\\pipe", "codex-ipc");
  }

  const uid = process.getuid?.();
  const filename = uid ? `ipc-${uid}.sock` : "ipc.sock";
  return path.join(os.tmpdir(), "codex-ipc", filename);
}

export function isCodexDesktopIpcAvailable(): boolean {
  return process.platform === "win32" || existsSync(codexDesktopIpcSocketPath());
}

export class CodexDesktopIpcClient {
  private socket: net.Socket | null = null;
  private connectInFlight: Promise<void> | null = null;
  private clientId = INITIALIZING_CLIENT_ID;
  private readBuffer = Buffer.alloc(0);
  private pendingFrameLength: number | null = null;
  private readonly pendingResponses = new Map<string, PendingResponse>();

  constructor(private readonly socketPath = codexDesktopIpcSocketPath()) {}

  async startTurn(
    threadId: string,
    input: CodexDesktopUserInput[]
  ): Promise<JSONValue | undefined> {
    return await this.request("thread-follower-start-turn", {
      conversationId: threadId,
      turnStartParams: {
        input: input as unknown as JSONValue,
        attachments: [],
      },
    });
  }

  async steerTurn(
    threadId: string,
    input: CodexDesktopUserInput[],
    restoreMessage: CodexDesktopQueuedFollowUp,
    attachments: JSONValue[] = []
  ): Promise<JSONValue | undefined> {
    return await this.request("thread-follower-steer-turn", {
      conversationId: threadId,
      input: input as unknown as JSONValue,
      attachments,
      restoreMessage: restoreMessage as unknown as JSONValue,
    });
  }

  async setQueuedFollowUpsState(
    threadId: string,
    state: CodexDesktopQueuedFollowUpsState
  ): Promise<JSONValue | undefined> {
    return await this.request("thread-follower-set-queued-follow-ups-state", {
      conversationId: threadId,
      state: state as unknown as JSONValue,
    });
  }

  async broadcastQueuedFollowUpsChanged(
    threadId: string,
    messages: CodexDesktopQueuedFollowUp[]
  ): Promise<void> {
    await this.broadcast("thread-queued-followups-changed", {
      conversationId: threadId,
      messages: messages as unknown as JSONValue,
    });
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    return await this.request("thread-follower-interrupt-turn", {
      conversationId: threadId,
    });
  }

  async setModelAndReasoning(
    threadId: string,
    model: string,
    reasoningEffort: string | null
  ): Promise<JSONValue | undefined> {
    return await this.request("thread-follower-set-model-and-reasoning", {
      conversationId: threadId,
      model,
      reasoningEffort,
    });
  }

  dispose(): void {
    this.rejectPendingResponses(new Error("Codex Desktop IPC client disposed"));
    this.socket?.destroy();
    this.socket = null;
  }

  private async connect(): Promise<void> {
    if (this.socket?.writable) {
      return;
    }

    if (this.connectInFlight) {
      await this.connectInFlight;
      return;
    }

    this.connectInFlight = this.openConnection();
    try {
      await this.connectInFlight;
    } finally {
      this.connectInFlight = null;
    }
  }

  private async openConnection(): Promise<void> {
    const socket = net.createConnection(this.socketPath);
    this.socket = socket;

    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        cleanup();
        socket.destroy();
        reject(new Error(`Codex Desktop IPC connect timed out: ${this.socketPath}`));
      }, CONNECT_TIMEOUT_MS);

      const cleanup = () => {
        clearTimeout(timeout);
        socket.off("connect", handleConnect);
        socket.off("error", handleError);
      };

      const handleConnect = () => {
        cleanup();
        resolve();
      };

      const handleError = (error: Error) => {
        cleanup();
        reject(error);
      };

      socket.once("connect", handleConnect);
      socket.once("error", handleError);
    });

    socket.on("data", (chunk) => {
      this.handleData(chunk);
    });
    socket.on("error", (error) => {
      this.rejectPendingResponses(error instanceof Error ? error : new Error(String(error)));
    });
    socket.on("close", () => {
      if (this.socket === socket) {
        this.socket = null;
        this.clientId = INITIALIZING_CLIENT_ID;
      }
      this.rejectPendingResponses(new Error("Codex Desktop IPC socket closed"));
    });

    const initialized = await this.sendRequest("initialize", {
      clientType: "helm-bridge",
    });
    if (initialized.resultType !== "success" || !isRecord(initialized.result)) {
      throw new Error(initialized.error ?? "Codex Desktop IPC initialize failed");
    }

    const initializedClientId = initialized.result.clientId;
    if (typeof initializedClientId !== "string" || initializedClientId.length === 0) {
      throw new Error("Codex Desktop IPC initialize did not return a client id");
    }
    this.clientId = initializedClientId;
  }

  private async request(method: string, params: JSONValue): Promise<JSONValue | undefined> {
    await this.connect();
    const response = await this.sendRequest(method, params);
    if (response.resultType === "error") {
      throw new CodexDesktopIpcRequestError(method, response.error ?? "unknown-error");
    }
    return response.result;
  }

  private async sendRequest(
    method: string,
    params: JSONValue | undefined,
    timeoutMs = DEFAULT_REQUEST_TIMEOUT_MS
  ): Promise<CodexDesktopIpcResponseMessage> {
    const socket = this.socket;
    if (!socket?.writable) {
      throw new Error("Codex Desktop IPC socket is not connected");
    }
    if (this.clientId === INITIALIZING_CLIENT_ID && method !== "initialize") {
      throw new Error("Codex Desktop IPC client is not initialized");
    }

    const requestId = randomUUID();
    const request = {
      type: "request",
      requestId,
      sourceClientId: this.clientId,
      version: REQUEST_VERSIONS.get(method) ?? 0,
      method,
      params,
    };

    const response = new Promise<CodexDesktopIpcResponseMessage>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingResponses.delete(requestId);
        reject(new Error(`Codex Desktop IPC request timed out: ${method}`));
      }, timeoutMs);
      this.pendingResponses.set(requestId, { resolve, reject, timeout });
    });

    try {
      writeFrame(socket, request);
    } catch (error) {
      const pending = this.pendingResponses.get(requestId);
      if (pending) {
        clearTimeout(pending.timeout);
        this.pendingResponses.delete(requestId);
      }
      throw error;
    }

    return await response;
  }

  private async broadcast(method: string, params: JSONValue): Promise<void> {
    await this.connect();
    const socket = this.socket;
    if (!socket?.writable) {
      throw new Error("Codex Desktop IPC socket is not connected");
    }
    if (this.clientId === INITIALIZING_CLIENT_ID) {
      throw new Error("Codex Desktop IPC client is not initialized");
    }

    writeFrame(socket, {
      type: "broadcast",
      method,
      sourceClientId: this.clientId,
      version: REQUEST_VERSIONS.get(method) ?? 0,
      params,
    });
  }

  private handleData(chunk: Buffer): void {
    this.readBuffer = Buffer.concat([this.readBuffer, chunk]);

    while (true) {
      if (this.pendingFrameLength === null) {
        if (this.readBuffer.length < 4) {
          return;
        }

        this.pendingFrameLength = this.readBuffer.readUInt32LE(0);
        this.readBuffer = this.readBuffer.subarray(4);
        if (this.pendingFrameLength > MAX_IPC_FRAME_BYTES) {
          this.socket?.destroy(new Error(`Codex Desktop IPC frame too large: ${this.pendingFrameLength}`));
          return;
        }
      }

      if (this.readBuffer.length < this.pendingFrameLength) {
        return;
      }

      const frame = this.readBuffer.subarray(0, this.pendingFrameLength);
      this.readBuffer = this.readBuffer.subarray(this.pendingFrameLength);
      this.pendingFrameLength = null;

      try {
        this.handleMessage(JSON.parse(frame.toString("utf8")) as unknown);
      } catch (error) {
        this.socket?.destroy(error instanceof Error ? error : new Error(String(error)));
        return;
      }
    }
  }

  private handleMessage(message: unknown): void {
    if (!isRecord(message) || typeof message.type !== "string") {
      return;
    }

    const typedMessage = message as CodexDesktopIpcMessage;
    switch (typedMessage.type) {
      case "response":
        this.handleResponse(typedMessage);
        return;
      case "client-discovery-request":
        this.writeClientDiscoveryResponse(typedMessage.requestId);
        return;
      case "request":
        this.writeUnhandledRequestResponse(typedMessage.requestId);
        return;
      case "broadcast":
        return;
    }
  }

  private handleResponse(message: CodexDesktopIpcResponseMessage): void {
    const pending = this.pendingResponses.get(message.requestId);
    if (!pending) {
      return;
    }

    this.pendingResponses.delete(message.requestId);
    clearTimeout(pending.timeout);
    pending.resolve(message);
  }

  private writeClientDiscoveryResponse(requestId: string): void {
    if (!this.socket?.writable) {
      return;
    }

    writeFrame(this.socket, {
      type: "client-discovery-response",
      requestId,
      response: {
        canHandle: false,
      },
    });
  }

  private writeUnhandledRequestResponse(requestId: string): void {
    if (!this.socket?.writable) {
      return;
    }

    writeFrame(this.socket, {
      type: "response",
      requestId,
      resultType: "error",
      error: "no-handler-for-request",
    });
  }

  private rejectPendingResponses(error: Error): void {
    for (const [requestId, pending] of this.pendingResponses.entries()) {
      this.pendingResponses.delete(requestId);
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
  }
}

function writeFrame(socket: net.Socket, message: unknown): void {
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  if (payload.length > MAX_IPC_FRAME_BYTES) {
    throw new Error(`Codex Desktop IPC frame too large: ${payload.length}`);
  }

  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length, 0);
  socket.write(Buffer.concat([header, payload]));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
