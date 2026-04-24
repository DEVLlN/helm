import { config } from "./config.js";
import { OpenAIVoiceProvider } from "./openAIVoiceProvider.js";
import type { JSONValue } from "./types.js";
import {
  buildVoiceInstructions,
  type VoiceClientSecretOptions,
  type VoiceProviderRequestContext,
  type VoiceProviderSummary,
  type VoiceRealtimeSessionOptions,
  type VoiceSpeechResult,
  VoiceProvider,
} from "./voiceProvider.js";

export type NvidiaAIVoiceConfig = {
  baseURL: string | null;
  apiKey: string | null;
  languageCode: string;
  voiceName: string;
  synthesisPath: string;
  healthPath: string;
  commandDriverModel: string;
  openAIAPIKey: string;
};

type NvidiaVoiceProbe = {
  ok: boolean;
  detail?: string;
  status?: number;
  checkedURL?: string;
};

type FetchLike = typeof fetch;

export type NvidiaAIVoiceProviderOptions = {
  voiceConfig?: NvidiaAIVoiceConfig;
  realtimeProvider?: OpenAIVoiceProvider;
  fetchFn?: FetchLike;
};

function baseSummary(): VoiceProviderSummary {
  return {
    id: "nvidia-ai-voice",
    label: "NVIDIA AI Voice",
    kind: "nvidia",
    transport: "openai-webrtc+nvidia-tts",
    available: false,
    availabilityDetail: "NVIDIA AI Voice is not configured.",
    supportsSpeechSynthesis: true,
    supportsRealtimeSessions: true,
    supportsClientSecrets: true,
    supportsNativeBootstrap: false,
  };
}

export function nvidiaAIVoiceConfigFromEnv(): NvidiaAIVoiceConfig {
  return {
    baseURL: config.nvidiaVoiceBaseURL,
    apiKey: config.nvidiaVoiceAPIKey,
    languageCode: config.nvidiaVoiceLanguageCode,
    voiceName: config.nvidiaVoiceName,
    synthesisPath: config.nvidiaVoiceSynthesisPath,
    healthPath: config.nvidiaVoiceHealthPath,
    commandDriverModel: config.commandModeDriverModel,
    openAIAPIKey: config.openAIAPIKey,
  };
}

export class NvidiaAIVoiceProvider extends VoiceProvider {
  private readonly voiceConfig: NvidiaAIVoiceConfig;
  private readonly realtimeProvider: OpenAIVoiceProvider;
  private readonly fetchFn: FetchLike;

  constructor(options: NvidiaAIVoiceProviderOptions = {}) {
    super(baseSummary());
    this.voiceConfig = options.voiceConfig ?? nvidiaAIVoiceConfigFromEnv();
    this.realtimeProvider = options.realtimeProvider ?? new OpenAIVoiceProvider();
    this.fetchFn = options.fetchFn ?? fetch;
  }

  override async getSummary(): Promise<VoiceProviderSummary> {
    const missing = this.missingConfigDetail();
    if (missing) {
      return {
        ...this.summary,
        available: false,
        availabilityDetail: missing,
      };
    }

    const probe = await this.probe();
    return {
      ...this.summary,
      available: probe.ok,
      availabilityDetail: probe.ok
        ? `NVIDIA Speech NIM reachable at ${probe.checkedURL ?? this.voiceConfig.baseURL}. Spoken output will use ${this.voiceConfig.voiceName}.`
        : probe.detail ?? "NVIDIA Speech NIM is configured but not reachable.",
    };
  }

  override async describeBootstrap(context: VoiceProviderRequestContext = {}): Promise<JSONValue | null> {
    const missing = this.missingConfigDetail();
    const probe = missing ? null : await this.probe();

    return {
      providerId: this.summary.id,
      transport: "openai-webrtc+nvidia-tts",
      configured: !missing,
      reachable: probe?.ok ?? false,
      detail: missing ?? probe?.detail ?? "NVIDIA Speech NIM is ready for bridge speech output.",
      nvidia: {
        baseUrl: this.voiceConfig.baseURL,
        healthPath: this.voiceConfig.healthPath,
        synthesisPath: this.voiceConfig.synthesisPath,
        languageCode: this.voiceConfig.languageCode,
        voiceName: this.voiceConfig.voiceName,
        api: {
          kind: "speech-nim-http",
          synthesis: "multipart/form-data POST to /v1/audio/synthesize",
        },
      },
      openai: {
        realtimeTransport: "delegated-openai-webrtc",
        commandDriverModel: this.voiceConfig.commandDriverModel,
        targetThreadId: context.threadId ?? null,
        targetBackendId: context.backendId ?? null,
      },
      helmStatus: {
        bridgeSpeechProxy: probe?.ok ?? false,
        bridgeRealtimeProxy: this.voiceConfig.openAIAPIKey.trim().length > 0,
        nativeBootstrapAvailable: false,
      },
    };
  }

  buildInstructions(style: string | null | undefined): string {
    const base = [
      config.voiceConfirmationInstructions,
      `Use ${this.voiceConfig.commandDriverModel} as the Command Mode background driver when planning support is enabled.`,
      "Use NVIDIA Speech NIM only for spoken output; keep command routing in helm.",
    ].join(" ");

    return buildVoiceInstructions(style, base);
  }

  async createClientSecret(options: VoiceClientSecretOptions = {}): Promise<unknown> {
    return await this.realtimeProvider.createClientSecret({
      ...options,
      instructions:
        options.instructions?.trim().length
          ? options.instructions.trim()
          : this.buildInstructions(null),
    });
  }

  async createRealtimeSessionAnswer(
    sdp: string,
    options: VoiceRealtimeSessionOptions = {}
  ): Promise<string> {
    return await this.realtimeProvider.createRealtimeSessionAnswer(sdp, {
      ...options,
      instructions:
        options.instructions?.trim().length
          ? options.instructions.trim()
          : this.buildInstructions(null),
    });
  }

  async createSpeechAudio(text: string): Promise<VoiceSpeechResult> {
    const missing = this.missingNvidiaConfigDetail();
    if (missing) {
      throw new Error(missing);
    }

    const url = this.urlForPath(this.voiceConfig.synthesisPath);
    const body = new FormData();
    body.set("language", this.voiceConfig.languageCode);
    body.set("text", text);
    if (this.voiceConfig.voiceName.trim().length > 0) {
      body.set("voice", this.voiceConfig.voiceName);
    }

    const headers = new Headers();
    headers.set("Accept", "audio/wav, audio/*");
    if (this.voiceConfig.apiKey?.trim()) {
      headers.set("Authorization", `Bearer ${this.voiceConfig.apiKey.trim()}`);
    }

    const response = await this.fetchFn(url.toString(), {
      method: "POST",
      headers,
      body,
    });

    if (!response.ok) {
      const responseBody = await response.text();
      throw new Error(`NVIDIA Speech NIM synthesis failed: ${response.status} ${responseBody}`);
    }

    return {
      audio: Buffer.from(await response.arrayBuffer()),
      contentType: response.headers.get("content-type") ?? "audio/wav",
    };
  }

  private async probe(): Promise<NvidiaVoiceProbe> {
    const missing = this.missingNvidiaConfigDetail();
    if (missing) {
      return {
        ok: false,
        detail: missing,
      };
    }

    try {
      const url = this.urlForPath(this.voiceConfig.healthPath);
      const headers = new Headers();
      if (this.voiceConfig.apiKey?.trim()) {
        headers.set("Authorization", `Bearer ${this.voiceConfig.apiKey.trim()}`);
      }

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 2500);
      const response = await this.fetchFn(url.toString(), {
        method: "GET",
        headers,
        signal: controller.signal,
      }).finally(() => clearTimeout(timeout));

      if (!response.ok) {
        return {
          ok: false,
          status: response.status,
          checkedURL: url.toString(),
          detail: `NVIDIA Speech NIM health check failed with ${response.status} ${response.statusText}.`,
        };
      }

      return {
        ok: true,
        status: response.status,
        checkedURL: url.toString(),
      };
    } catch (error) {
      return {
        ok: false,
        checkedURL: this.voiceConfig.baseURL ?? undefined,
        detail:
          error instanceof Error
            ? `NVIDIA Speech NIM health check failed: ${error.message}`
            : "NVIDIA Speech NIM health check failed.",
      };
    }
  }

  private missingConfigDetail(): string | null {
    const missingNvidia = this.missingNvidiaConfigDetail();
    if (missingNvidia) {
      return missingNvidia;
    }

    if (!this.voiceConfig.openAIAPIKey.trim()) {
      return "NVIDIA AI Voice needs OPENAI_API_KEY for the ChatGPT-backed Live Command transport.";
    }

    return null;
  }

  private missingNvidiaConfigDetail(): string | null {
    if (!this.voiceConfig.baseURL?.trim()) {
      return "NVIDIA AI Voice is not configured. Set NVIDIA_VOICE_BASE_URL to a reachable NVIDIA Speech NIM HTTP endpoint.";
    }

    return null;
  }

  private urlForPath(path: string): URL {
    return new URL(path, this.voiceConfig.baseURL!);
  }
}
