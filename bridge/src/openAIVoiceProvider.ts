import { config } from "./config.js";
import {
  buildVoiceInstructions,
  type VoiceClientSecretOptions,
  type VoiceRealtimeSessionOptions,
  type VoiceSpeechResult,
  VoiceProvider,
} from "./voiceProvider.js";

export class OpenAIVoiceProvider extends VoiceProvider {
  constructor() {
    super({
      id: "openai-realtime",
      label: "OpenAI Realtime",
      kind: "openai",
      transport: "openai-webrtc",
      available: true,
      supportsSpeechSynthesis: true,
      supportsRealtimeSessions: true,
      supportsClientSecrets: true,
      supportsNativeBootstrap: false,
    });
  }

  buildInstructions(style: string | null | undefined): string {
    return buildVoiceInstructions(style, config.voiceConfirmationInstructions);
  }

  async createClientSecret(options: VoiceClientSecretOptions = {}): Promise<unknown> {
    const apiKey = config.requireOpenAIKey();
    const instructions =
      options.instructions?.trim().length ? options.instructions.trim() : config.voiceConfirmationInstructions;

    const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        session: {
          type: "realtime",
          model: config.openAIRealtimeModel,
          instructions,
          audio: {
            output: {
              voice: config.openAIRealtimeVoice,
            },
          },
        },
      }),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Failed to create Realtime client secret: ${response.status} ${body}`);
    }

    return await response.json();
  }

  async createRealtimeSessionAnswer(
    sdp: string,
    options: VoiceRealtimeSessionOptions = {}
  ): Promise<string> {
    const apiKey = config.requireOpenAIKey();
    const mode = options.mode ?? "realtime";

    const session =
      mode === "transcription"
        ? {
            type: "transcription",
            audio: {
              input: {
                transcription: {
                  model: config.openAIRealtimeTranscriptionModel,
                  language: "en",
                },
                turn_detection: {
                  type: "server_vad",
                  create_response: false,
                  interrupt_response: true,
                },
              },
            },
          }
        : {
            type: "realtime",
            model: config.openAIRealtimeModel,
            instructions:
              options.instructions?.trim().length
                ? options.instructions.trim()
                : config.voiceConfirmationInstructions,
            audio: {
              output: {
                voice: config.openAIRealtimeVoice,
              },
            },
          };

    const formData = new FormData();
    formData.set("sdp", sdp);
    formData.set("session", JSON.stringify(session));

    const response = await fetch("https://api.openai.com/v1/realtime/calls", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
      },
      body: formData,
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Failed to create Realtime session answer: ${response.status} ${body}`);
    }

    return await response.text();
  }

  async createSpeechAudio(text: string): Promise<VoiceSpeechResult> {
    const apiKey = config.requireOpenAIKey();

    const response = await fetch("https://api.openai.com/v1/audio/speech", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: config.openAITTSModel,
        voice: config.openAITTSVoice,
        input: text,
      }),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`Failed to create speech audio: ${response.status} ${body}`);
    }

    const audio = Buffer.from(await response.arrayBuffer());
    return {
      audio,
      contentType: response.headers.get("content-type") ?? "audio/mpeg",
    };
  }
}
