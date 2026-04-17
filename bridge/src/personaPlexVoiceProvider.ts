import { config } from "./config.js";
import type { JSONValue } from "./types.js";
import {
  type VoiceClientSecretOptions,
  type VoiceNativeProxyTarget,
  type VoiceProviderRequestContext,
  type VoiceProviderSummary,
  type VoiceRealtimeSessionOptions,
  type VoiceSpeechResult,
  VoiceProvider,
} from "./voiceProvider.js";

type PersonaPlexProbe = {
  ok: boolean;
  detail?: string;
  status?: number;
  checkedURL?: string;
};

function baseSummary(): VoiceProviderSummary {
  return {
    id: "personaplex",
    label: "PersonaPlex",
    kind: "personaplex",
    transport: "personaplex-websocket",
    available: false,
    availabilityDetail: "PersonaPlex is not configured.",
    supportsSpeechSynthesis: false,
    supportsRealtimeSessions: false,
    supportsClientSecrets: false,
    supportsNativeBootstrap: true,
  };
}

function missingConfigDetail(): string {
  return "PersonaPlex is not configured. Set PERSONAPLEX_BASE_URL after you have a PersonaPlex server ready.";
}

function unsupportedDetail(): string {
  return "PersonaPlex uses its own websocket conversation flow at /api/chat. helm does not proxy that native session yet.";
}

export class PersonaPlexVoiceProvider extends VoiceProvider {
  constructor() {
    super(baseSummary());
  }

  override async getSummary(): Promise<VoiceProviderSummary> {
    if (!config.personaPlexBaseURL) {
      return {
        ...this.summary,
        available: false,
        availabilityDetail: missingConfigDetail(),
      };
    }

    const probe = await this.probe();
    return {
      ...this.summary,
      available: probe.ok,
      availabilityDetail: probe.ok
        ? `PersonaPlex server reachable at ${probe.checkedURL ?? config.personaPlexBaseURL}. Native websocket bootstrap is available through helm`
        : probe.detail ?? unsupportedDetail(),
    };
  }

  override async describeBootstrap(context: VoiceProviderRequestContext = {}): Promise<JSONValue | null> {
    if (!config.personaPlexBaseURL) {
      return {
        providerId: this.summary.id,
        transport: "personaplex-websocket",
        configured: false,
        detail: missingConfigDetail(),
        bridgeProxy: {
          websocketPath: "/ws/voice/personaplex",
          auth: "helm pairing token required via Authorization header or token query parameter.",
        },
      };
    }

    const probe = await this.probe();
    const baseURL = new URL(config.personaPlexBaseURL);
    const websocketURL = this.websocketURL(baseURL);

    return {
      providerId: this.summary.id,
      transport: "personaplex-websocket",
      configured: true,
      reachable: probe.ok,
      detail: probe.ok ? "PersonaPlex native websocket path is reachable." : (probe.detail ?? unsupportedDetail()),
      baseUrl: baseURL.toString(),
      websocketUrl: websocketURL,
      auth: {
        mode: config.personaPlexAuthToken ? "bearer-optional" : "none",
        header: config.personaPlexAuthToken ? "Authorization: Bearer <PERSONAPLEX_AUTH_TOKEN>" : null,
      },
      query: {
        required: [
          "text_prompt",
          "voice_prompt",
        ],
        optional: [
          "worker_auth_id",
          "email",
          "text_temperature",
          "text_topk",
          "audio_temperature",
          "audio_topk",
          "pad_mult",
          "text_seed",
          "audio_seed",
          "repetition_penalty_context",
          "repetition_penalty",
        ],
        suggestedValues: {
          text_prompt: this.personaPlexTextPrompt(context),
          voice_prompt: "NATF0.pt",
        },
      },
      protocol: {
        handshake: "Binary websocket. Server sends 0x00 handshake when ready.",
        uplink: [
          "0x01 + opus audio bytes",
        ],
        downlink: [
          "0x01 + opus audio bytes",
          "0x02 + utf-8 text deltas",
          "0x00 handshake",
        ],
        notes: "This is a native PersonaPlex/Moshi session, not an OpenAI WebRTC or client-secret flow.",
      },
      bridgeProxy: {
        websocketPath: "/ws/voice/personaplex",
        auth: "helm pairing token required via Authorization header or token query parameter.",
      },
      helmStatus: {
        bridgeSpeechProxy: false,
        bridgeRealtimeProxy: probe.ok,
        nativeBootstrapAvailable: probe.ok,
      },
    };
  }

  override async createNativeProxyTarget(
    context: VoiceProviderRequestContext = {},
    query: URLSearchParams
  ): Promise<VoiceNativeProxyTarget | null> {
    if (!config.personaPlexBaseURL) {
      throw new Error(missingConfigDetail());
    }

    const probe = await this.probe();
    if (!probe.ok) {
      throw new Error(probe.detail ?? unsupportedDetail());
    }

    const target = new URL(this.websocketURL(new URL(config.personaPlexBaseURL)));
    const headers: Record<string, string> = {};

    if (config.personaPlexAuthToken) {
      headers["Authorization"] = `Bearer ${config.personaPlexAuthToken}`;
    }

    target.searchParams.set(
      "text_prompt",
      this.firstNonEmpty(query.get("text_prompt"), this.personaPlexTextPrompt(context))
    );
    target.searchParams.set(
      "voice_prompt",
      this.firstNonEmpty(query.get("voice_prompt"), "NATF0.pt")
    );

    for (const key of [
      "worker_auth_id",
      "email",
      "text_temperature",
      "text_topk",
      "audio_temperature",
      "audio_topk",
      "pad_mult",
      "text_seed",
      "audio_seed",
      "repetition_penalty_context",
      "repetition_penalty",
    ]) {
      const value = query.get(key)?.trim();
      if (value) {
        target.searchParams.set(key, value);
      }
    }

    return {
      url: target.toString(),
      headers,
    };
  }

  async createClientSecret(_options: VoiceClientSecretOptions = {}): Promise<unknown> {
    throw new Error(unsupportedDetail());
  }

  async createRealtimeSessionAnswer(
    _sdp: string,
    _options: VoiceRealtimeSessionOptions = {}
  ): Promise<string> {
    throw new Error(unsupportedDetail());
  }

  async createSpeechAudio(_text: string): Promise<VoiceSpeechResult> {
    throw new Error(unsupportedDetail());
  }

  private async probe(): Promise<PersonaPlexProbe> {
    try {
      const url = new URL(config.personaPlexBaseURL!);
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2500);
      const headers = new Headers();

      if (config.personaPlexAuthToken) {
        headers.set("Authorization", `Bearer ${config.personaPlexAuthToken}`);
      }

      const response = await fetch(url, {
        method: "GET",
        headers,
        redirect: "follow",
        signal: controller.signal,
      });
      clearTimeout(timeout);

      if (!response.ok) {
        return {
          ok: false,
          detail: `PersonaPlex probe failed with ${response.status} ${response.statusText}.`,
          status: response.status,
          checkedURL: url.toString(),
        };
      }

      const body = await response.text();
      const looksLikePersonaPlex =
        body.includes("PersonaPlex") || body.includes("/api/chat") || body.includes("Full duplex conversational AI");

      if (!looksLikePersonaPlex) {
        return {
          ok: false,
          detail: `PersonaPlex probe reached ${url.toString()} but the response did not look like a PersonaPlex frontend.`,
          status: response.status,
          checkedURL: url.toString(),
        };
      }

      return {
        ok: true,
        status: response.status,
        checkedURL: url.toString(),
      };
    } catch (error) {
      const detail =
        error instanceof Error
          ? `PersonaPlex probe failed: ${error.message}`
          : "PersonaPlex probe failed.";
      return {
        ok: false,
        detail,
        checkedURL: config.personaPlexBaseURL ?? undefined,
      };
    }
  }

  private websocketURL(baseURL: URL): string {
    const socketURL = new URL(baseURL.toString());
    socketURL.protocol = socketURL.protocol === "https:" ? "wss:" : "ws:";
    socketURL.pathname = "/api/chat";
    socketURL.search = "";
    return socketURL.toString();
  }

  private personaPlexTextPrompt(context: VoiceProviderRequestContext): string {
    const backendLabel = context.backendId?.trim().length ? context.backendId!.trim() : "the active coding backend";
    return [
      "You are helm Command.",
      `You are the live spoken control layer for ${backendLabel}.`,
      "Acknowledge briefly, stay mostly silent while work runs, and only speak when a checkpoint, blocker, approval, or completion matters.",
    ].join(" ");
  }

  private firstNonEmpty(primary: string | null, fallback: string): string {
    const trimmed = primary?.trim();
    return trimmed && trimmed.length > 0 ? trimmed : fallback;
  }
}
