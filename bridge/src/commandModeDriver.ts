import { config } from "./config.js";
import type {
  CommandModeDriverSummary,
  CommandModeSummary,
} from "./types.js";
import type { VoiceProviderSummary } from "./voiceProvider.js";

export type CommandModeDriverEnvironment = {
  apiKey: string;
  model: string;
};

export function buildCommandModeDriverSummary(
  environment: CommandModeDriverEnvironment
): CommandModeDriverSummary {
  const model = environment.model.trim() || "gpt-5.5";
  const available = environment.apiKey.trim().length > 0;

  return {
    id: "openai-chatgpt",
    label: displayModelLabel(model),
    kind: "openai",
    model,
    available,
    availabilityDetail: available
      ? undefined
      : "Set OPENAI_API_KEY before enabling ChatGPT-backed Command Mode planning.",
  };
}

export class CommandModeDriver {
  getSummary(): CommandModeDriverSummary {
    return buildCommandModeDriverSummary({
      apiKey: config.openAIAPIKey,
      model: config.commandModeDriverModel,
    });
  }

  buildSummary(voiceProvider?: VoiceProviderSummary | null): CommandModeSummary {
    return {
      driver: this.getSummary(),
      routing: "threadTurns",
      voiceProviderId: voiceProvider?.id,
      voiceProviderLabel: voiceProvider?.label,
      notes:
        "Command Mode currently routes accepted spoken text into the selected thread. The driver metadata is the attachment point for background intent planning.",
    };
  }
}

function displayModelLabel(model: string): string {
  if (model === "gpt-5.5") {
    return "ChatGPT 5.5";
  }

  return model;
}
