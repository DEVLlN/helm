import net from "node:net";

import type { RuntimeLaunchRecord } from "./runtimeLaunchRegistry.js";

type RelayRequest =
  | {
      type: "sendText";
      text: string;
      pressEnter?: boolean;
      segments?: RelayInputSegment[];
    }
  | {
      type: "interrupt";
    }
  | {
      type: "sendInput";
      text: string;
    };

type RelayResponse = {
  ok?: boolean;
  error?: string;
};

type SendTextOptions = {
  clearPromptFirst?: boolean;
  clearPromptMode?: "dismissAutocomplete" | "promptOnly";
  inputMode?: "typewrite" | "bracketedPaste";
  pressEnter?: boolean;
  postPasteDelayMs?: number;
  submitWithTabBeforeEnter?: boolean;
};

type RelayInputSegment = {
  text: string;
  delayAfterMs?: number;
  mode?: "burst" | "typewrite";
};

const PROMPT_CLEAR_PREFIX_BY_MODE = {
  dismissAutocomplete: "\x1b\x15",
  promptOnly: "\x15",
} as const;
const BRACKETED_PASTE_START = "\x1b[200~";
const BRACKETED_PASTE_END = "\x1b[201~";
const TAB_SUBMIT_SUFFIX = "\t";

function inputPayload(text: string, mode: SendTextOptions["inputMode"]): string {
  if (mode !== "bracketedPaste") {
    return text;
  }

  return `${BRACKETED_PASTE_START}${text.replace(/\r\n?/g, "\n")}${BRACKETED_PASTE_END}`;
}

async function sendRelayRequest(launch: RuntimeLaunchRecord, request: RelayRequest): Promise<void> {
  const socketPath = launch.ipcSocket;
  if (!socketPath) {
    throw new Error("helm shell relay is not available for this session.");
  }

  await new Promise<void>((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let settled = false;
    let buffer = "";

    const cleanup = () => {
      socket.removeAllListeners();
      socket.destroy();
    };

    const finish = (error?: Error) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    };

    socket.setTimeout(6_000, () => finish(new Error("helm shell relay timed out.")));

    socket.once("error", (error) => finish(error));
    socket.once("connect", () => {
      socket.write(`${JSON.stringify(request)}\n`);
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const newlineIndex = buffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }

      const line = buffer.slice(0, newlineIndex);
      try {
        const response = JSON.parse(line) as RelayResponse;
        if (response.ok) {
          finish();
          return;
        }
        finish(new Error(response.error ?? "helm shell relay rejected the request."));
      } catch (error) {
        finish(error instanceof Error ? error : new Error("Invalid helm shell relay response."));
      }
    });
  });
}

export async function sendTextViaRuntimeRelay(
  launch: RuntimeLaunchRecord,
  text: string,
  options: SendTextOptions = {}
): Promise<void> {
  const clearMode = options.clearPromptMode ?? "dismissAutocomplete";
  const prefix = options.clearPromptFirst ? PROMPT_CLEAR_PREFIX_BY_MODE[clearMode] : "";
  const body = inputPayload(text, options.inputMode);
  const suffix = options.submitWithTabBeforeEnter ? TAB_SUBMIT_SUFFIX : "";
  const segments: RelayInputSegment[] = [];
  if (prefix) {
    segments.push({ text: prefix, mode: "burst" });
  }
  if (body) {
    segments.push({
      text: body,
      mode: options.inputMode === "bracketedPaste" ? "burst" : "typewrite",
      delayAfterMs: options.inputMode === "bracketedPaste" ? options.postPasteDelayMs : undefined,
    });
  }
  if (suffix) {
    segments.push({ text: suffix, mode: "burst" });
  }

  await sendRelayRequest(launch, {
    type: "sendText",
    text: `${prefix}${body}${suffix}`,
    pressEnter: options.pressEnter ?? true,
    segments,
  });
}

export async function interruptViaRuntimeRelay(launch: RuntimeLaunchRecord): Promise<void> {
  await sendRelayRequest(launch, {
    type: "interrupt",
  });
}

export async function sendInputViaRuntimeRelay(launch: RuntimeLaunchRecord, text: string): Promise<void> {
  await sendRelayRequest(launch, {
    type: "sendInput",
    text,
  });
}
