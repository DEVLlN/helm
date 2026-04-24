import type {
  JSONValue,
  VoiceCommandRequest,
  VoiceSpeechRequest,
} from "./types.js";

export type VoiceProviderSummary = {
  id: string;
  label: string;
  kind: "openai" | "personaplex" | "nvidia" | "custom";
  transport?: "openai-webrtc" | "personaplex-websocket" | "openai-webrtc+nvidia-tts" | "custom";
  available: boolean;
  availabilityDetail?: string;
  supportsSpeechSynthesis: boolean;
  supportsRealtimeSessions: boolean;
  supportsClientSecrets: boolean;
  supportsNativeBootstrap?: boolean;
};

export type VoiceNativeProxyTarget = {
  url: string;
  headers?: Record<string, string>;
  protocols?: string[];
};

export type VoiceClientSecretOptions = {
  instructions?: string;
};

export type VoiceRealtimeSessionOptions = {
  mode?: "realtime" | "transcription";
  instructions?: string;
};

export type VoiceSpeechResult = {
  audio: Buffer;
  contentType: string;
};

export type VoiceProviderRequestContext = {
  voiceProviderId?: string | null;
  style?: VoiceCommandRequest["style"] | VoiceSpeechRequest["style"] | null;
  threadId?: string | null;
  backendId?: string | null;
};

export abstract class VoiceProvider {
  constructor(readonly summary: VoiceProviderSummary) {}

  async getSummary(): Promise<VoiceProviderSummary> {
    return this.summary;
  }

  async describeBootstrap(_context: VoiceProviderRequestContext = {}): Promise<JSONValue | null> {
    return null;
  }

  async createNativeProxyTarget(
    _context: VoiceProviderRequestContext = {},
    _query: URLSearchParams
  ): Promise<VoiceNativeProxyTarget | null> {
    return null;
  }

  abstract createClientSecret(options?: VoiceClientSecretOptions): Promise<unknown>;
  abstract createRealtimeSessionAnswer(
    sdp: string,
    options?: VoiceRealtimeSessionOptions
  ): Promise<string>;
  abstract createSpeechAudio(text: string): Promise<VoiceSpeechResult>;
}

export function buildVoiceInstructions(style: string | null | undefined, baseInstructions: string): string {
  const base = baseInstructions.trim();

  const styleInstruction = (() => {
    switch ((style ?? "").trim()) {
      case "concise":
        return "Keep spoken acknowledgements, progress updates, and confirmations extremely short.";
      case "formal":
        return "Use formal, polished phrasing while staying concise and action-oriented.";
      case "jarvis":
        return "Use a poised assistant cadence with subtle J.A.R.V.I.S.-style acknowledgements, but stay concise.";
      case "codex":
      default:
        return "Sound like normal Codex: calm, direct, brief, and technically grounded.";
    }
  })();

  return `${base} ${styleInstruction} Acknowledge briefly, stay mostly silent while Codex works, and only speak when a checkpoint, blocker, approval, or completion matters.`;
}
