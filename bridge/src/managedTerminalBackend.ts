import { accessSync, constants, existsSync } from "node:fs";
import { basename } from "node:path";

import { AgentBackend, type StartThreadInput } from "./agentBackend.js";
import { interruptViaRuntimeRelay, sendInputViaRuntimeRelay, sendTextViaRuntimeRelay } from "./runtimeRelayClient.js";
import {
  findMatchingLaunchByCWD,
  findMatchingLaunchByPID,
  isRuntimeRelayAvailable,
  listRuntimeLaunches,
  readRuntimeOutputTail,
  type RuntimeLaunchRecord,
} from "./runtimeLaunchRegistry.js";
import { launchManagedCommandDetached, resolveUnderlyingRuntimeBinary } from "./runtimeShellLauncher.js";
import type {
  BackendCommandSemantics,
  BackendSummary,
  JSONRPCId,
  JSONValue,
  StartTurnFileAttachment,
  StartTurnOptions,
  ThreadSummary,
} from "./types.js";

type ManagedTerminalBackendConfig = {
  id: string;
  label: string;
  kind: string;
  description: string;
  runtime: string;
  commandCandidates: string[];
  availabilityDetail?: string;
  unavailableDetail: string;
  installHint: string;
  defaultModel?: string | null;
  modelOptions?: string[];
  buildArgs?: (input: StartThreadInput, model: string | null) => string[];
  env?: (input: StartThreadInput, model: string | null) => NodeJS.ProcessEnv | undefined;
  wrapperName?: string;
  command?: Partial<BackendCommandSemantics>;
};

const MANAGED_TERMINAL_LAUNCH_WAIT_MS = 5_000;
const MANAGED_TERMINAL_POLL_MS = 100;

function truncate(text: string, maxLength: number): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  return `${trimmed.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function isExecutable(candidate: string): boolean {
  if (!existsSync(candidate)) {
    return false;
  }

  try {
    accessSync(candidate, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveFromPath(candidates: string[]): string | null {
  const pathEntries = (process.env.PATH ?? "")
    .split(":")
    .map((entry) => entry.trim())
    .filter(Boolean);

  for (const candidate of candidates) {
    if (candidate.includes("/") && isExecutable(candidate)) {
      return candidate;
    }

    for (const entry of pathEntries) {
      const fullPath = `${entry}/${candidate}`;
      if (isExecutable(fullPath)) {
        return fullPath;
      }
    }
  }

  return null;
}

function resolveCommand(runtime: string, candidates: string[]): string | null {
  if (runtime === "grok") {
    const resolved = resolveUnderlyingRuntimeBinary("grok");
    if (resolved.includes("/") && isExecutable(resolved)) {
      return resolved;
    }
    return resolveFromPath(candidates);
  }

  return resolveFromPath(candidates);
}

function mergeCommandSemantics(
  override: Partial<BackendCommandSemantics> | undefined
): BackendCommandSemantics {
  return {
    routing: "providerChat",
    approvals: "providerManaged",
    handoff: "isolated",
    voiceInput: "localSpeech",
    voiceOutput: "none",
    supportsCommandFollowups: true,
    notes:
      "helm runs this provider as a managed terminal process and injects follow-up turns through the runtime relay. Provider-native session persistence depends on the underlying CLI.",
    ...override,
  };
}

function textWithFileAttachments(text: string, attachments: StartTurnFileAttachment[]): string {
  if (attachments.length === 0) {
    return text;
  }

  const attachmentLines = attachments.map((attachment) => {
    const label = attachment.filename?.trim() || attachment.path;
    return `- ${label}: ${attachment.path}`;
  });

  return `${text.trim()}\n\nAttached files available on this Mac:\n${attachmentLines.join("\n")}`.trim();
}

export class ManagedTerminalBackend extends AgentBackend {
  private readonly config: ManagedTerminalBackendConfig;
  private readonly commandPath: string | null;

  constructor(config: ManagedTerminalBackendConfig) {
    const commandPath = resolveCommand(config.runtime, config.commandCandidates);
    const available = Boolean(commandPath);
    const command = mergeCommandSemantics(config.command);
    const summary: BackendSummary = {
      id: config.id,
      label: config.label,
      kind: config.kind,
      description: config.description,
      isDefault: false,
      available,
      availabilityDetail: available
        ? (config.availabilityDetail ?? `${config.label} is available through helm's managed terminal relay.`)
        : config.unavailableDetail,
      capabilities: {
        threadListing: available,
        threadCreation: available,
        turnExecution: available,
        turnInterrupt: available,
        approvals: false,
        planMode: false,
        voiceCommand: true,
        realtimeVoice: false,
        hooksAndSkillsParity: false,
        sharedThreadHandoff: false,
      },
      command,
    };

    super(summary);
    this.config = config;
    this.commandPath = commandPath;
  }

  async connect(): Promise<void> {
    return;
  }

  async listThreads(): Promise<ThreadSummary[]> {
    if (!this.summary.available) {
      return [];
    }

    return listRuntimeLaunches(this.config.runtime).map((launch) => this.threadSummaryFromLaunch(launch));
  }

  async startThread(input: StartThreadInput = {}): Promise<JSONValue | undefined> {
    if (!this.summary.available || !this.commandPath) {
      throw this.unavailableError();
    }

    const cwd = input.cwd?.trim() || process.cwd();
    const model = input.model?.trim() || this.config.defaultModel || null;
    const args = this.config.buildArgs?.(input, model) ?? [];
    const launchedAt = Date.now();
    await launchManagedCommandDetached({
      runtime: this.config.runtime,
      cwd,
      command: this.commandPath,
      args,
      env: this.config.env?.(input, model),
      wrapperName: this.config.wrapperName ?? `helm-${this.config.runtime}`,
    });

    const launch = await this.waitForLaunch(cwd, launchedAt - 2_000);
    return {
      thread: this.threadSummaryFromLaunch(launch),
      launched: true,
      launchMode: "managedShell",
    };
  }

  async readThread(threadId: string): Promise<JSONValue | undefined> {
    const launch = this.launchForThreadId(threadId);
    const summary = this.threadSummaryFromLaunch(launch);
    const tail = readRuntimeOutputTail(launch);
    const rawText = tail?.text ?? null;

    return {
      thread: {
        id: summary.id,
        name: summary.name,
        cwd: summary.cwd,
        workspacePath: summary.workspacePath ?? null,
        status: summary.status,
        updatedAt: summary.updatedAt,
        sourceKind: summary.sourceKind,
        launchSource: summary.launchSource ?? null,
        backendId: this.summary.id,
        backendLabel: this.summary.label,
        backendKind: this.summary.kind,
        command: this.summary.command,
        affordances: {
          canSendTurns: true,
          canInterrupt: true,
          canRespondToApprovals: false,
          canUseRealtimeCommand: false,
          showsOperationalSnapshot: true,
          sessionAccess: "helmManagedShell",
          notes:
            "This is a helm-managed terminal session. Mobile can inject text and interrupts while the underlying provider owns its transcript.",
        },
        turns: [
          {
            id: `turn-${launch.pid}`,
            status: "running",
            items: [
              {
                id: `terminal-${launch.pid}`,
                turnId: `turn-${launch.pid}`,
                type: "commandExecution",
                title: `${this.summary.label} Terminal`,
                detail: rawText ? "Live terminal output captured by helm." : "Waiting for terminal output.",
                status: "running",
                rawText,
                metadataSummary: null,
                command: this.commandLabel(),
                cwd: launch.cwd,
                exitCode: null,
              },
            ],
          },
        ],
      },
    };
  }

  async startTurn(threadId: string, text: string, options: StartTurnOptions = {}): Promise<JSONValue | undefined> {
    if (options.imageAttachments?.length) {
      throw new Error(`${this.summary.label} image attachments are not supported through the terminal relay yet.`);
    }

    const launch = this.launchForThreadId(threadId);
    if (options.deliveryMode === "interrupt") {
      await interruptViaRuntimeRelay(launch);
      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    const prompt = textWithFileAttachments(text, options.fileAttachments ?? []);
    await sendTextViaRuntimeRelay(launch, prompt, {
      inputMode: "bracketedPaste",
    });
    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  async interruptTurn(threadId: string): Promise<JSONValue | undefined> {
    const launch = this.launchForThreadId(threadId);
    await interruptViaRuntimeRelay(launch);
    return {
      ok: true,
      mode: "shellRelay",
      threadId,
    };
  }

  async sendInput(threadId: string, input: string): Promise<JSONValue | undefined> {
    const launch = this.launchForThreadId(threadId);
    await sendInputViaRuntimeRelay(launch, input);
    return {
      ok: true,
      mode: "shellRelayInput",
      threadId,
    };
  }

  async renameThread(_threadId: string, _name: string): Promise<JSONValue | undefined> {
    throw new Error(`${this.summary.label} does not support renaming managed terminal sessions yet.`);
  }

  respond(_id: JSONRPCId, _result: JSONValue): void {
    throw new Error(`${this.summary.label} does not expose approval responses through helm yet.`);
  }

  private async waitForLaunch(cwd: string, launchedAt: number): Promise<RuntimeLaunchRecord> {
    const deadline = Date.now() + MANAGED_TERMINAL_LAUNCH_WAIT_MS;
    let fallback: RuntimeLaunchRecord | null = null;

    while (Date.now() < deadline) {
      const launch = findMatchingLaunchByCWD(this.config.runtime, cwd, launchedAt);
      if (launch) {
        fallback = launch;
        if (isRuntimeRelayAvailable(launch)) {
          return launch;
        }
      }
      await new Promise((resolve) => setTimeout(resolve, MANAGED_TERMINAL_POLL_MS));
    }

    if (fallback) {
      return fallback;
    }

    throw new Error(`${this.summary.label} launched but did not register a managed terminal session.`);
  }

  private threadSummaryFromLaunch(launch: RuntimeLaunchRecord): ThreadSummary {
    const tail = readRuntimeOutputTail(launch);
    const cwdName = basename(launch.cwd) || launch.cwd || this.summary.label;
    const preview =
      tail?.text ?? `${this.summary.label} is running as a helm-managed terminal session.`;

    return {
      id: this.threadIdForLaunch(launch),
      name: `${this.summary.label} - ${cwdName}`,
      preview: truncate(preview, 180),
      cwd: launch.cwd,
      workspacePath: null,
      status: "running",
      updatedAt: tail?.updatedAt ?? launch.launchedAt,
      sourceKind: "managed-terminal",
      launchSource: "helm-managed-shell",
      backendId: this.summary.id,
      backendLabel: this.summary.label,
      backendKind: this.summary.kind,
      controller: null,
    };
  }

  private threadIdForLaunch(launch: RuntimeLaunchRecord): string {
    return launch.threadId?.trim() || `${this.config.runtime}:${launch.pid}`;
  }

  private launchForThreadId(threadId: string): RuntimeLaunchRecord {
    const normalized = threadId.trim();
    const pid = this.pidFromThreadId(normalized);
    const launch = pid
      ? findMatchingLaunchByPID(this.config.runtime, pid)
      : listRuntimeLaunches(this.config.runtime).find((record) => this.threadIdForLaunch(record) === normalized);

    if (!isRuntimeRelayAvailable(launch)) {
      throw new Error(`${this.summary.label} session is not reachable through the helm runtime relay.`);
    }

    return launch;
  }

  private pidFromThreadId(threadId: string): number | null {
    const prefix = `${this.config.runtime}:`;
    if (!threadId.startsWith(prefix)) {
      return null;
    }
    const pid = Number(threadId.slice(prefix.length));
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  }

  private commandLabel(): string {
    if (this.config.defaultModel) {
      return `${this.config.commandCandidates[0]} ${this.config.defaultModel}`;
    }
    return this.config.commandCandidates[0] ?? this.summary.label;
  }

  private unavailableError(): Error {
    return new Error(`${this.summary.availabilityDetail ?? this.config.installHint}`);
  }
}
