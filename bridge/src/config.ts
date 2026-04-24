import dotenv from "dotenv";
import { homedir } from "node:os";
import { join } from "node:path";

dotenv.config();

function requiredEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function optionalEnv(name: string, fallback: string): string {
  const value = process.env[name]?.trim();
  return value && value.length > 0 ? value : fallback;
}

export const config = {
  bridgeHost: optionalEnv("BRIDGE_HOST", "0.0.0.0"),
  bridgePort: Number.parseInt(optionalEnv("BRIDGE_PORT", "8787"), 10),
  bridgePreferredURL: process.env.BRIDGE_PREFERRED_URL?.trim() || null,
  codexAppServerUrl: optionalEnv("CODEX_APP_SERVER_URL", "ws://127.0.0.1:6060"),
  bridgePairingFile: optionalEnv(
    "BRIDGE_PAIRING_FILE",
    join(homedir(), "Library", "Application Support", "Helm", "bridge-pairing.json")
  ),
  bridgePairingToken: process.env.BRIDGE_PAIRING_TOKEN?.trim() || null,
  openAIAPIKey: process.env.OPENAI_API_KEY?.trim() ?? "",
  openAIRealtimeModel: optionalEnv("OPENAI_REALTIME_MODEL", "gpt-realtime-1.5"),
  openAIRealtimeVoice: optionalEnv("OPENAI_REALTIME_VOICE", "marin"),
  openAIRealtimeTranscriptionModel: optionalEnv(
    "OPENAI_REALTIME_TRANSCRIPTION_MODEL",
    "gpt-4o-mini-transcribe"
  ),
  openAITTSModel: optionalEnv("OPENAI_TTS_MODEL", "gpt-4o-mini-tts"),
  openAITTSVoice: optionalEnv("OPENAI_TTS_VOICE", "marin"),
  commandModeDriverModel: optionalEnv(
    "COMMAND_MODE_DRIVER_MODEL",
    optionalEnv("OPENAI_COMMAND_DRIVER_MODEL", "gpt-5.5")
  ),
  defaultVoiceProviderId: optionalEnv("DEFAULT_VOICE_PROVIDER_ID", "openai-realtime"),
  nvidiaVoiceBaseURL: process.env.NVIDIA_VOICE_BASE_URL?.trim() || null,
  nvidiaVoiceAPIKey:
    process.env.NVIDIA_VOICE_API_KEY?.trim() || process.env.NVIDIA_API_KEY?.trim() || null,
  nvidiaVoiceLanguageCode: optionalEnv("NVIDIA_VOICE_LANGUAGE_CODE", "en-US"),
  nvidiaVoiceName: optionalEnv("NVIDIA_VOICE_NAME", "Magpie-Multilingual.EN-US.Aria"),
  nvidiaVoiceSynthesisPath: optionalEnv("NVIDIA_VOICE_SYNTHESIS_PATH", "/v1/audio/synthesize"),
  nvidiaVoiceHealthPath: optionalEnv("NVIDIA_VOICE_HEALTH_PATH", "/v1/health/ready"),
  personaPlexBaseURL: process.env.PERSONAPLEX_BASE_URL?.trim() || null,
  personaPlexAuthToken: process.env.PERSONAPLEX_AUTH_TOKEN?.trim() || null,
  voiceConfirmationInstructions: optionalEnv(
    "VOICE_CONFIRMATION_INSTRUCTIONS",
    "You are the voice layer for a remote Codex session. Be concise and action-oriented."
  ),
  requireOpenAIKey(): string {
    return requiredEnv("OPENAI_API_KEY");
  },
};
