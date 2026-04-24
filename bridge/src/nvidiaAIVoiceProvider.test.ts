import test from "node:test";
import assert from "node:assert/strict";

import {
  NvidiaAIVoiceProvider,
  type NvidiaAIVoiceConfig,
} from "./nvidiaAIVoiceProvider.js";

function voiceConfig(overrides: Partial<NvidiaAIVoiceConfig> = {}): NvidiaAIVoiceConfig {
  return {
    baseURL: "http://localhost:9000",
    apiKey: "nv-key",
    languageCode: "en-US",
    voiceName: "Magpie-Multilingual.EN-US.Aria",
    synthesisPath: "/v1/audio/synthesize",
    healthPath: "/v1/health/ready",
    commandDriverModel: "gpt-5.5",
    openAIAPIKey: "sk-test",
    ...overrides,
  };
}

function requestURL(input: RequestInfo | URL): string {
  if (typeof input === "string") {
    return input;
  }

  if (input instanceof URL) {
    return input.toString();
  }

  return input.url;
}

test("NVIDIA AI voice summary explains missing base URL", async () => {
  const provider = new NvidiaAIVoiceProvider({
    voiceConfig: voiceConfig({ baseURL: null }),
    fetchFn: async () => new Response(null, { status: 500 }),
  });

  const summary = await provider.getSummary();

  assert.equal(summary.id, "nvidia-ai-voice");
  assert.equal(summary.available, false);
  assert.match(summary.availabilityDetail ?? "", /NVIDIA_VOICE_BASE_URL/);
});

test("NVIDIA AI voice summary requires OpenAI key for live command transport", async () => {
  const provider = new NvidiaAIVoiceProvider({
    voiceConfig: voiceConfig({ openAIAPIKey: "" }),
    fetchFn: async () => new Response(JSON.stringify({ status: "ready" }), { status: 200 }),
  });

  const summary = await provider.getSummary();

  assert.equal(summary.available, false);
  assert.match(summary.availabilityDetail ?? "", /OPENAI_API_KEY/);
});

test("NVIDIA AI voice synthesizes through Speech NIM HTTP form endpoint", async () => {
  const requests: Array<{ url: string; init?: RequestInit }> = [];
  const fetchFn: typeof fetch = async (input, init) => {
    requests.push({ url: requestURL(input), init });

    if (init?.method === "GET") {
      return new Response(JSON.stringify({ status: "ready" }), { status: 200 });
    }

    return new Response(Buffer.from("RIFF"), {
      status: 200,
      headers: {
        "Content-Type": "audio/wav",
      },
    });
  };
  const provider = new NvidiaAIVoiceProvider({
    voiceConfig: voiceConfig(),
    fetchFn,
  });

  const summary = await provider.getSummary();
  const speech = await provider.createSpeechAudio("Ship it.");

  assert.equal(summary.available, true);
  assert.equal(speech.contentType, "audio/wav");
  assert.equal(speech.audio.toString(), "RIFF");

  const post = requests.find((request) => request.init?.method === "POST");
  assert.ok(post);
  assert.equal(post.url, "http://localhost:9000/v1/audio/synthesize");

  const headers = post.init?.headers;
  assert.ok(headers instanceof Headers);
  assert.equal(headers.get("Authorization"), "Bearer nv-key");

  const body = post.init?.body;
  assert.ok(body instanceof FormData);
  assert.equal(body.get("language"), "en-US");
  assert.equal(body.get("text"), "Ship it.");
  assert.equal(body.get("voice"), "Magpie-Multilingual.EN-US.Aria");
});
