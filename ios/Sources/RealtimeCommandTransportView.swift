import SwiftUI
import WebKit

struct RealtimeCommandTransportView: UIViewRepresentable {
    let bridgeURL: String
    let pairingToken: String
    let clientID: String
    let clientName: String
    let style: String
    let threadID: String?
    let backendID: String?
    let voiceProviderID: String?
    let active: Bool
    let playbackRequest: RealtimePlaybackRequest?
    let playbackStopToken: UUID
    let onState: @MainActor (String, String?) -> Void
    let onEvent: @MainActor (String, String?) -> Void
    let onPartialTranscript: @MainActor (String) -> Void
    let onFinalTranscript: @MainActor (String) -> Void
    let onCommandExchange: @MainActor (RealtimeCommandExchange) -> Void
    let onCommandFailure: @MainActor (String?, String, String, Int?) -> Void
    let onPlaybackFinished: @MainActor () -> Void
    let onPlaybackInterrupted: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onState: onState,
            onEvent: onEvent,
            onPartialTranscript: onPartialTranscript,
            onFinalTranscript: onFinalTranscript,
            onCommandExchange: onCommandExchange,
            onCommandFailure: onCommandFailure,
            onPlaybackFinished: onPlaybackFinished,
            onPlaybackInterrupted: onPlaybackInterrupted
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "helmRealtime")

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString(Self.html, baseURL: nil)
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let payload: [String: String] = [
            "bridgeURL": bridgeURL,
            "pairingToken": pairingToken,
            "clientID": clientID,
            "clientName": clientName,
            "style": style,
            "threadID": threadID ?? "",
            "backendID": backendID ?? "",
            "voiceProviderID": voiceProviderID ?? "",
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        let script =
            active
            ? "window.helmRealtimeConnect(\(json));"
            : "window.helmRealtimeDisconnect();"

        webView.evaluateJavaScript(script)

        if let playbackRequest, context.coordinator.lastPlaybackRequestID != playbackRequest.id {
            context.coordinator.lastPlaybackRequestID = playbackRequest.id
            let payload = ["text": playbackRequest.text]
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
            else {
                return
            }

            webView.evaluateJavaScript("window.helmRealtimeSpeak(\(json));")
        }

        if context.coordinator.lastPlaybackStopToken != playbackStopToken {
            context.coordinator.lastPlaybackStopToken = playbackStopToken
            webView.evaluateJavaScript("window.helmRealtimeInterruptOutput();")
        }
    }

    static let html = #"""
    <!doctype html>
    <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0" />
      </head>
      <body style="margin:0;background:transparent;">
        <script>
          var peerConnection = null;
          var dataChannel = null;
          var mediaStream = null;
          var currentConfig = null;
          var playbackAudio = null;
          const dispatchCooldownMS = 2500;
          const lastCommandDispatch = { transcript: "", at: 0 };
          var connecting = false;
          var partialTranscript = "";
          var personaPlexSocket = null;
          var personaPlexRecorder = null;
          var personaPlexAudioContext = null;
          var personaPlexSource = null;
          var personaPlexAnalyser = null;
          var personaPlexDecoderWorker = null;
          var personaPlexOutputNode = null;
          var personaPlexOutputModulePromise = null;
          var personaPlexDispatchTimer = null;
          var personaPlexTranscript = "";
          var personaPlexScriptPromise = null;
          var personaPlexScheduledSources = [];
          var personaPlexPlaybackQuietAt = 0;
          var personaPlexNextPlaybackTime = 0;

          function post(message) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.helmRealtime) {
              window.webkit.messageHandlers.helmRealtime.postMessage(message);
            }
          }

          function summarize(event) {
            if (typeof event.transcript === "string" && event.transcript.length > 0) {
              return event.transcript;
            }
            if (typeof event.delta === "string" && event.delta.length > 0) {
              return event.delta;
            }
            if (typeof event.item_id === "string") {
              return "Item " + event.item_id;
            }
            return "";
          }

          function decodeErrorText(text) {
            if (!text || typeof text !== "string") {
              return "Request failed.";
            }

            try {
              const parsed = JSON.parse(text);
              if (parsed && typeof parsed.error === "string" && parsed.error.length > 0) {
                return parsed.error;
              }
            } catch (_) {}

            return text;
          }

          async function cleanup() {
            stopPlayback();

            if (personaPlexDispatchTimer) {
              clearTimeout(personaPlexDispatchTimer);
              personaPlexDispatchTimer = null;
            }

            if (personaPlexRecorder) {
              try { personaPlexRecorder.stop(); } catch (_) {}
              personaPlexRecorder = null;
            }

            if (personaPlexSocket) {
              try { personaPlexSocket.close(); } catch (_) {}
              personaPlexSocket = null;
            }

            if (personaPlexSource) {
              try { personaPlexSource.disconnect(); } catch (_) {}
              personaPlexSource = null;
            }

            if (personaPlexAnalyser) {
              try { personaPlexAnalyser.disconnect(); } catch (_) {}
              personaPlexAnalyser = null;
            }

            if (personaPlexDecoderWorker) {
              try { personaPlexDecoderWorker.terminate(); } catch (_) {}
              personaPlexDecoderWorker = null;
            }

            if (personaPlexOutputNode) {
              try { personaPlexOutputNode.port.postMessage({ command: "reset" }); } catch (_) {}
              try { personaPlexOutputNode.disconnect(); } catch (_) {}
              personaPlexOutputNode = null;
            }

            stopScheduledPersonaPlexSources();

            if (personaPlexAudioContext) {
              try { await personaPlexAudioContext.close(); } catch (_) {}
              personaPlexAudioContext = null;
            }

            if (dataChannel) {
              try { dataChannel.close(); } catch (_) {}
              dataChannel = null;
            }

            if (peerConnection) {
              try { peerConnection.close(); } catch (_) {}
              peerConnection = null;
            }

            if (mediaStream) {
              for (const track of mediaStream.getTracks()) {
                try { track.stop(); } catch (_) {}
              }
              mediaStream = null;
            }

            partialTranscript = "";
            personaPlexTranscript = "";
            personaPlexPlaybackQuietAt = 0;
            personaPlexNextPlaybackTime = 0;
            connecting = false;
          }

          function sameConfig(lhs, rhs) {
            if (!lhs || !rhs) {
              return false;
            }

            return lhs.bridgeURL === rhs.bridgeURL
              && lhs.pairingToken === rhs.pairingToken
              && lhs.style === rhs.style
              && lhs.threadID === rhs.threadID
              && lhs.backendID === rhs.backendID
              && lhs.voiceProviderID === rhs.voiceProviderID;
          }

          function stopPlayback() {
            const hadPlayback =
              !!playbackAudio
              || personaPlexScheduledSources.length > 0
              || personaPlexPlaybackQuietAt > Date.now();

            if (playbackAudio) {
              try { playbackAudio.pause(); } catch (_) {}
              try {
                if (playbackAudio.src) {
                  URL.revokeObjectURL(playbackAudio.src);
                }
              } catch (_) {}
              playbackAudio = null;
            }

            stopScheduledPersonaPlexSources();
            if (personaPlexOutputNode) {
              try { personaPlexOutputNode.port.postMessage({ command: "reset" }); } catch (_) {}
            }
            personaPlexPlaybackQuietAt = 0;
            personaPlexNextPlaybackTime = personaPlexAudioContext ? personaPlexAudioContext.currentTime : 0;
            return hadPlayback;
          }

          function stopScheduledPersonaPlexSources() {
            if (!personaPlexScheduledSources.length) {
              return;
            }

            for (const source of personaPlexScheduledSources) {
              try { source.stop(); } catch (_) {}
              try { source.disconnect(); } catch (_) {}
            }
            personaPlexScheduledSources = [];
          }

          function handleRealtimeEvent(rawMessage) {
            let event;
            try {
              event = JSON.parse(rawMessage.data);
            } catch (_) {
              post({ kind: "event", title: "Realtime Event", detail: "Received a non-JSON event." });
              return;
            }

            const type = event.type || "event";

            if (type === "conversation.item.input_audio_transcription.delta" && typeof event.delta === "string") {
              partialTranscript += event.delta;
              post({ kind: "partialTranscript", text: partialTranscript });
              return;
            }

            if (type === "conversation.item.input_audio_transcription.completed" && typeof event.transcript === "string") {
              partialTranscript = "";
              post({ kind: "finalTranscript", text: event.transcript });
              dispatchCommandTranscript(event.transcript);
              return;
            }

            if (type === "input_audio_buffer.speech_started") {
              if (stopPlayback()) {
                post({ kind: "playbackInterrupted" });
              }
              post({ kind: "state", state: "listening", detail: "Speech detected." });
              return;
            }

            if (type === "input_audio_buffer.speech_stopped") {
              post({ kind: "event", title: "Speech Ended", detail: "Waiting for transcript." });
              return;
            }

            post({ kind: "event", title: type, detail: summarize(event) });
          }

          async function dispatchCommandTranscript(transcript) {
            const trimmed = typeof transcript === "string" ? transcript.trim() : "";
            if (!currentConfig || trimmed.length === 0) {
              return;
            }

            const now = Date.now();
            if (trimmed === lastCommandDispatch.transcript && (now - lastCommandDispatch.at) < dispatchCooldownMS) {
              return;
            }

            lastCommandDispatch.transcript = trimmed;
            lastCommandDispatch.at = now;

            const requestStartedAt = Date.now();
            post({ kind: "state", state: "dispatching", detail: "Sending the spoken Command." });

            try {
              const url = new URL("/api/voice/command", currentConfig.bridgeURL);
              const headers = { "Content-Type": "application/json" };
              if (currentConfig.pairingToken && currentConfig.pairingToken.length > 0) {
                headers["Authorization"] = "Bearer " + currentConfig.pairingToken;
              }

              const body = {
                threadId: currentConfig.threadID,
                text: trimmed,
                style: currentConfig.style,
                clientId: currentConfig.clientID,
                clientName: currentConfig.clientName
              };

              const response = await fetch(url.toString(), {
                method: "POST",
                headers,
                body: JSON.stringify(body)
              });

              if (!response.ok) {
                throw new Error(decodeErrorText(await response.text()) || "Failed to send the spoken Command.");
              }

              const payload = await response.json();
              const backend = payload && payload.backend ? payload.backend : null;
              const spokenResponse = typeof payload.spokenResponse === "string" && payload.spokenResponse.trim().length > 0
                ? payload.spokenResponse.trim()
                : null;
              const transportHandlesSpeech = true;

              post({
                kind: "commandExchange",
                threadID: currentConfig.threadID || "",
                transcript: trimmed,
                acknowledgement: typeof payload.acknowledgement === "string" && payload.acknowledgement.trim().length > 0
                  ? payload.acknowledgement.trim()
                  : "On it.",
                displayResponse: typeof payload.displayResponse === "string" && payload.displayResponse.trim().length > 0
                  ? payload.displayResponse.trim()
                  : "On it.",
                spokenResponse,
                shouldResumeListening: payload.shouldResumeListening !== false,
                backendID: backend && typeof backend.id === "string" ? backend.id : "",
                backendLabel: backend && typeof backend.label === "string" ? backend.label : "",
                latencyMS: Date.now() - requestStartedAt
              });

              if (spokenResponse && transportHandlesSpeech) {
                await helmRealtimeSpeak({
                  text: spokenResponse,
                  resumeListening: payload.shouldResumeListening !== false
                });
              } else if (payload.shouldResumeListening !== false) {
                post({ kind: "state", state: "listening", detail: "Listening for the next Command." });
              }
            } catch (error) {
              const detail = error && error.message ? error.message : String(error);
              post({
                kind: "commandFailure",
                threadID: currentConfig.threadID || "",
                transcript: trimmed,
                detail,
                latencyMS: Date.now() - requestStartedAt
              });
            }
          }

          async function ensurePersonaPlexRecorder() {
            if (window.Recorder) {
              return;
            }

            if (!personaPlexScriptPromise) {
              personaPlexScriptPromise = new Promise((resolve, reject) => {
                const script = document.createElement("script");
                script.src = "https://unpkg.com/opus-recorder@8.0.5/dist/recorder.min.js";
                script.async = true;
                script.onload = () => resolve();
                script.onerror = () => reject(new Error("Failed to load opus-recorder for PersonaPlex."));
                document.head.appendChild(script);
              });
            }

            await personaPlexScriptPromise;

            if (!window.Recorder) {
              throw new Error("PersonaPlex recorder did not become available.");
            }
          }

          async function ensurePersonaPlexDecoder(config) {
            if (personaPlexDecoderWorker || !config || !config.bridgeURL) {
              return;
            }

            if (!personaPlexAudioContext) {
              throw new Error("PersonaPlex audio context is not ready.");
            }

            const jsURL = new URL("/api/voice/providers/personaplex/assets/decoderWorker.min.js", config.bridgeURL);
            const wasmURL = new URL("/api/voice/providers/personaplex/assets/decoderWorker.min.wasm", config.bridgeURL);
            if (config.pairingToken && config.pairingToken.length > 0) {
              jsURL.searchParams.set("token", config.pairingToken);
              wasmURL.searchParams.set("token", config.pairingToken);
            }

            const response = await fetch(jsURL.toString(), {
              headers: config.pairingToken && config.pairingToken.length > 0
                ? { "Authorization": "Bearer " + config.pairingToken }
                : {}
            });

            if (!response.ok) {
              throw new Error("Failed to load PersonaPlex decoder worker.");
            }

            const workerSource = await response.text();
            const wrappedSource = `
              var Module = {
                locateFile: function(path) {
                  if (path === "decoderWorker.min.wasm") {
                    return ${JSON.stringify(wasmURL.toString())};
                  }
                  return path;
                }
              };
              ${workerSource}
            `;
            const blob = new Blob([wrappedSource], { type: "application/javascript" });
            const workerURL = URL.createObjectURL(blob);
            const worker = new Worker(workerURL);
            URL.revokeObjectURL(workerURL);

            worker.onmessage = (event) => {
              const frame = event && event.data ? event.data[0] : null;
              if (!frame || !personaPlexAudioContext) {
                return;
              }

              const floatFrame = frame instanceof Float32Array ? frame : new Float32Array(frame);
              if (!floatFrame.length) {
                return;
              }

              const sampleRate = personaPlexAudioContext.sampleRate;
              const durationMS = (floatFrame.length / sampleRate) * 1000;
              personaPlexPlaybackQuietAt = Math.max(personaPlexPlaybackQuietAt, Date.now()) + durationMS;

              if (personaPlexOutputNode) {
                personaPlexOutputNode.port.postMessage(
                  {
                    command: "push",
                    samples: floatFrame,
                  },
                  [floatFrame.buffer]
                );
                return;
              }

              const buffer = personaPlexAudioContext.createBuffer(1, floatFrame.length, sampleRate);
              buffer.copyToChannel(floatFrame, 0);
              const source = personaPlexAudioContext.createBufferSource();
              source.buffer = buffer;
              source.connect(personaPlexAudioContext.destination);
              personaPlexScheduledSources.push(source);
              source.onended = () => {
                personaPlexScheduledSources = personaPlexScheduledSources.filter((entry) => entry !== source);
              };

              const startAt = Math.max(personaPlexAudioContext.currentTime + 0.02, personaPlexNextPlaybackTime);
              source.start(startAt);
              personaPlexNextPlaybackTime = startAt + buffer.duration;
            };

            worker.postMessage({
              command: "init",
              bufferLength: 960 * personaPlexAudioContext.sampleRate / 24000,
              decoderSampleRate: 24000,
              outputBufferSampleRate: personaPlexAudioContext.sampleRate,
              resampleQuality: 0
            });

            setTimeout(() => {
              const warmupBosPage = new Uint8Array([
                0x4F, 0x67, 0x67, 0x53,
                0x00,
                0x02,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00,
                0x01,
                0x13,
                0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64,
                0x01,
                0x01,
                0x38, 0x01,
                0x80, 0xBB, 0x00, 0x00,
                0x00, 0x00,
                0x00,
              ]);
              worker.postMessage({
                command: "decode",
                pages: warmupBosPage,
              });
            }, 100);

            personaPlexDecoderWorker = worker;
          }

          async function ensurePersonaPlexOutputNode() {
            if (personaPlexOutputNode || !personaPlexAudioContext) {
              return;
            }

            if (!personaPlexAudioContext.audioWorklet || typeof AudioWorkletNode === "undefined") {
              return;
            }

            if (!personaPlexOutputModulePromise) {
              const moduleSource = `
                class HelmPersonaPlexOutputProcessor extends AudioWorkletProcessor {
                  constructor() {
                    super();
                    this.queue = [];
                    this.current = null;
                    this.offset = 0;
                    this.port.onmessage = (event) => {
                      const payload = event.data || {};
                      if (payload.command === "reset") {
                        this.queue = [];
                        this.current = null;
                        this.offset = 0;
                        return;
                      }

                      if (payload.command === "push" && payload.samples) {
                        const frame = payload.samples instanceof Float32Array
                          ? payload.samples
                          : new Float32Array(payload.samples);
                        if (frame.length > 0) {
                          this.queue.push(frame);
                        }
                      }
                    };
                  }

                  process(inputs, outputs) {
                    const output = outputs[0] && outputs[0][0];
                    if (!output) {
                      return true;
                    }

                    output.fill(0);
                    let writeOffset = 0;
                    while (writeOffset < output.length) {
                      if (!this.current) {
                        this.current = this.queue.shift() || null;
                        this.offset = 0;
                        if (!this.current) {
                          break;
                        }
                      }

                      const remaining = this.current.length - this.offset;
                      const count = Math.min(remaining, output.length - writeOffset);
                      output.set(this.current.subarray(this.offset, this.offset + count), writeOffset);
                      this.offset += count;
                      writeOffset += count;

                      if (this.offset >= this.current.length) {
                        this.current = null;
                        this.offset = 0;
                      }
                    }

                    return true;
                  }
                }

                registerProcessor("helm-personaplex-output", HelmPersonaPlexOutputProcessor);
              `;
              const blob = new Blob([moduleSource], { type: "application/javascript" });
              const moduleURL = URL.createObjectURL(blob);
              personaPlexOutputModulePromise = personaPlexAudioContext.audioWorklet
                .addModule(moduleURL)
                .finally(() => {
                  URL.revokeObjectURL(moduleURL);
                });
            }

            await personaPlexOutputModulePromise;
            const node = new AudioWorkletNode(personaPlexAudioContext, "helm-personaplex-output", {
              outputChannelCount: [1],
            });
            node.connect(personaPlexAudioContext.destination);
            personaPlexOutputNode = node;
          }

          function buildPersonaPlexProxyURL(config) {
            return buildPersonaPlexProxyURLForMode(config, "command");
          }

          function buildPersonaPlexProxyURLForMode(config, mode) {
            const wsBase = new URL(config.bridgeURL);
            wsBase.protocol = wsBase.protocol === "https:" ? "wss:" : "ws:";
            wsBase.pathname = "/ws/voice/personaplex";
            wsBase.search = "";

            if (config.pairingToken && config.pairingToken.length > 0) {
              wsBase.searchParams.set("token", config.pairingToken);
            }
            if (config.threadID && config.threadID.length > 0) {
              wsBase.searchParams.set("threadId", config.threadID);
            } else if (config.backendID && config.backendID.length > 0) {
              wsBase.searchParams.set("backendId", config.backendID);
            }
            wsBase.searchParams.set("style", config.style || "codex");
            wsBase.searchParams.set(
              "text_prompt",
              mode === "speech"
                ? "You are helm speaking for a coding assistant. Convert the provided text into one brief natural spoken response. Keep it concise, preserve the key meaning, and do not ask follow-up questions."
                : "Transcribe the user's spoken coding request into one concise plain-text helm command. Do not acknowledge. Do not answer conversationally. Return only the intended command text."
            );
            wsBase.searchParams.set("voice_prompt", "NATF0.pt");
            wsBase.searchParams.set("text_temperature", "0");
            wsBase.searchParams.set("audio_temperature", "0.2");
            return wsBase.toString();
          }

          function encodePersonaPlexTextMessage(text) {
            const encoded = new TextEncoder().encode(text);
            const framed = new Uint8Array(encoded.length + 1);
            framed[0] = 0x02;
            framed.set(encoded, 1);
            return framed;
          }

          function encodePersonaPlexControlMessage(action) {
            const code = action === "start"
              ? 0x00
              : action === "endTurn"
                ? 0x01
                : action === "pause"
                  ? 0x02
                  : 0x03;
            return new Uint8Array([0x03, code]);
          }

          function waitForPersonaPlexPlaybackToDrain() {
            return new Promise((resolve) => {
              const startedAt = Date.now();
              const check = () => {
                if (personaPlexPlaybackQuietAt <= Date.now() + 120) {
                  resolve();
                  return;
                }

                if (Date.now() - startedAt > 15000) {
                  resolve();
                  return;
                }

                setTimeout(check, 120);
              };
              check();
            });
          }

          function schedulePersonaPlexDispatch() {
            if (personaPlexDispatchTimer) {
              clearTimeout(personaPlexDispatchTimer);
            }

            personaPlexDispatchTimer = setTimeout(async () => {
              const transcript = typeof personaPlexTranscript === "string"
                ? personaPlexTranscript.trim()
                : "";

              if (!transcript) {
                return;
              }

              partialTranscript = "";
              personaPlexTranscript = "";
              post({ kind: "finalTranscript", text: transcript });
              await dispatchCommandTranscript(transcript);
            }, 900);
          }

          function handlePersonaPlexMessage(rawMessage) {
            const bytes = new Uint8Array(rawMessage.data);
            if (bytes.length === 0) {
              return;
            }

            const kind = bytes[0];
            const payload = bytes.slice(1);

            if (kind === 0x00) {
              startPersonaPlexRecorder();
              post({ kind: "state", state: "connected", detail: "PersonaPlex proxy connected." });
              post({ kind: "state", state: "listening", detail: "Listening for Command." });
              return;
            }

            if (kind === 0x02) {
              const delta = new TextDecoder().decode(payload);
              personaPlexTranscript += delta;
              post({ kind: "partialTranscript", text: personaPlexTranscript });
              schedulePersonaPlexDispatch();
              return;
            }

            if (kind === 0x01) {
              if (personaPlexDecoderWorker) {
                personaPlexDecoderWorker.postMessage({
                  command: "decode",
                  pages: payload,
                });
              }
              return;
            }
          }

          function startPersonaPlexRecorder() {
            if (!mediaStream || personaPlexRecorder) {
              return;
            }

            personaPlexRecorder = new window.Recorder({
              encoderPath: "https://unpkg.com/opus-recorder@8.0.5/dist/encoderWorker.min.js",
              bufferLength: Math.round(960 * personaPlexAudioContext.sampleRate / 24000),
              encoderFrameSize: 20,
              encoderSampleRate: 24000,
              maxFramesPerPage: 2,
              numberOfChannels: 1,
              recordingGain: 1,
              resampleQuality: 3,
              encoderComplexity: 0,
              encoderApplication: 2049,
              streamPages: true,
            });

            personaPlexRecorder.ondataavailable = (data) => {
              if (!personaPlexSocket || personaPlexSocket.readyState !== WebSocket.OPEN) {
                return;
              }
              const chunk = data instanceof Uint8Array ? data : new Uint8Array(data);
              const framed = new Uint8Array(chunk.length + 1);
              framed[0] = 0x01;
              framed.set(chunk, 1);
              personaPlexSocket.send(framed);
            };

            personaPlexRecorder.onstop = () => {
              personaPlexRecorder = null;
            };

            personaPlexRecorder.start();
          }

          async function helmPersonaPlexConnect(config) {
            currentConfig = config;
            connecting = true;
            post({ kind: "state", state: "connecting", detail: "Opening PersonaPlex microphone access." });

            try {
              await ensurePersonaPlexRecorder();
              mediaStream = await navigator.mediaDevices.getUserMedia({
                audio: {
                  echoCancellation: true,
                  noiseSuppression: true,
                  autoGainControl: true,
                  channelCount: 1,
                }
              });

              personaPlexAudioContext = new (window.AudioContext || window.webkitAudioContext)();
              await personaPlexAudioContext.resume();
              personaPlexSource = personaPlexAudioContext.createMediaStreamSource(mediaStream);
              personaPlexAnalyser = personaPlexAudioContext.createAnalyser();
              personaPlexSource.connect(personaPlexAnalyser);
              await ensurePersonaPlexOutputNode();
              await ensurePersonaPlexDecoder(config);

              partialTranscript = "";
              personaPlexTranscript = "";

              const ws = new WebSocket(buildPersonaPlexProxyURL(config));
              ws.binaryType = "arraybuffer";
              ws.onmessage = handlePersonaPlexMessage;
              ws.onclose = () => {
                if (personaPlexSocket === ws) {
                  personaPlexSocket = null;
                  post({ kind: "state", state: "disconnected", detail: "PersonaPlex session closed." });
                }
              };
              ws.onerror = () => {
                post({ kind: "state", state: "error", detail: "PersonaPlex session failed." });
              };
              personaPlexSocket = ws;
              post({ kind: "event", title: "PersonaPlex", detail: "Waiting for PersonaPlex handshake." });
            } catch (error) {
              const detail = error && error.message ? error.message : String(error);
              post({ kind: "state", state: "error", detail });
              await cleanup();
            } finally {
              connecting = false;
            }
          }

          async function helmPersonaPlexSpeak(payload) {
            if (!currentConfig || !payload || !payload.text) {
              return;
            }

            if (!personaPlexAudioContext) {
              personaPlexAudioContext = new (window.AudioContext || window.webkitAudioContext)();
            }
            await personaPlexAudioContext.resume();
            await ensurePersonaPlexOutputNode();
            await ensurePersonaPlexDecoder(currentConfig);

            stopPlayback();
            post({ kind: "state", state: "playing", detail: "Speaking through PersonaPlex." });

            const shouldResumeListening = payload.resumeListening !== false;
            const speechText = String(payload.text).trim();
            if (!speechText) {
              if (shouldResumeListening) {
                post({ kind: "state", state: "listening", detail: "Listening for the next Command." });
              }
              return;
            }

            await new Promise((resolve, reject) => {
              const ws = new WebSocket(buildPersonaPlexProxyURLForMode(currentConfig, "speech"));
              let resolved = false;
              let completionTimer = null;
              let activityTimer = null;
              let audioReceived = false;

              const finalize = (error) => {
                if (resolved) {
                  return;
                }
                resolved = true;
                if (completionTimer) {
                  clearTimeout(completionTimer);
                  completionTimer = null;
                }
                if (activityTimer) {
                  clearTimeout(activityTimer);
                  activityTimer = null;
                }
                try { ws.close(); } catch (_) {}
                if (error) {
                  reject(error);
                } else {
                  resolve();
                }
              };

              const scheduleCompletion = () => {
                if (completionTimer) {
                  clearTimeout(completionTimer);
                }
                completionTimer = setTimeout(async () => {
                  await waitForPersonaPlexPlaybackToDrain();
                  finalize(null);
                }, 180);
              };

              const scheduleActivityTimeout = () => {
                if (activityTimer) {
                  clearTimeout(activityTimer);
                }
                activityTimer = setTimeout(() => {
                  if (audioReceived) {
                    scheduleCompletion();
                    return;
                  }
                  finalize(new Error("PersonaPlex did not return spoken audio."));
                }, 7000);
              };

              ws.binaryType = "arraybuffer";
              ws.onopen = () => {
                scheduleActivityTimeout();
              };
              ws.onerror = () => {
                finalize(new Error("PersonaPlex speech session failed."));
              };
              ws.onclose = () => {
                if (audioReceived) {
                  scheduleCompletion();
                  return;
                }
                finalize(null);
              };
              ws.onmessage = async (rawMessage) => {
                const bytes = new Uint8Array(rawMessage.data);
                if (bytes.length === 0) {
                  return;
                }

                const kind = bytes[0];
                const payloadBytes = bytes.slice(1);
                scheduleActivityTimeout();

                if (kind === 0x00) {
                  ws.send(encodePersonaPlexControlMessage("start"));
                  ws.send(encodePersonaPlexTextMessage(speechText));
                  ws.send(encodePersonaPlexControlMessage("endTurn"));
                  return;
                }

                if (kind === 0x01) {
                  audioReceived = true;
                  if (personaPlexDecoderWorker) {
                    personaPlexDecoderWorker.postMessage({
                      command: "decode",
                      pages: payloadBytes,
                    });
                  }
                  scheduleCompletion();
                  return;
                }

                if (kind === 0x02) {
                  scheduleCompletion();
                  return;
                }

                if (kind === 0x05) {
                  const detail = new TextDecoder().decode(payloadBytes) || "PersonaPlex returned an error.";
                  finalize(new Error(detail));
                }
              };
            });

            post({ kind: "playbackFinished" });
            if (shouldResumeListening) {
              post({ kind: "state", state: "listening", detail: "Listening for the next Command." });
            }
          }

          async function helmRealtimeConnect(config) {
            if (sameConfig(currentConfig, config) && (peerConnection || personaPlexSocket || connecting)) {
              return;
            }

            if ((peerConnection || personaPlexSocket || connecting) && !sameConfig(currentConfig, config)) {
              post({ kind: "state", state: "connecting", detail: "Switching Live Command to the new session." });
              await cleanup();
            }

            currentConfig = config;

            if (config.voiceProviderID === "personaplex") {
              await helmPersonaPlexConnect(config);
              return;
            }

            connecting = true;
            post({ kind: "state", state: "connecting", detail: "Opening microphone access." });

            try {
              mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true });

              peerConnection = new RTCPeerConnection();
              mediaStream.getTracks().forEach(track => peerConnection.addTrack(track, mediaStream));

              dataChannel = peerConnection.createDataChannel("oai-events");
              dataChannel.addEventListener("open", () => {
                post({ kind: "state", state: "connected", detail: "Realtime transcription channel open." });
              });
              dataChannel.addEventListener("message", handleRealtimeEvent);

              peerConnection.onconnectionstatechange = () => {
                const state = peerConnection ? peerConnection.connectionState : "disconnected";
                const detail = "Peer connection " + state + ".";

                if (state === "connected") {
                  post({ kind: "state", state: "listening", detail: "Listening for Command." });
                } else if (state === "failed" || state === "closed" || state === "disconnected") {
                  post({ kind: "state", state: "disconnected", detail });
                } else {
                  post({ kind: "state", state, detail });
                }
              };

              const offer = await peerConnection.createOffer();
              await peerConnection.setLocalDescription(offer);

              const url = new URL("/api/realtime/session", config.bridgeURL);
              url.searchParams.set("mode", "transcription");
              url.searchParams.set("style", config.style);
              if (config.threadID && config.threadID.length > 0) {
                url.searchParams.set("threadId", config.threadID);
              } else if (config.backendID && config.backendID.length > 0) {
                url.searchParams.set("backendId", config.backendID);
              }
              if (config.voiceProviderID && config.voiceProviderID.length > 0) {
                url.searchParams.set("voiceProviderId", config.voiceProviderID);
              }

              const headers = { "Content-Type": "application/sdp" };
              if (config.pairingToken && config.pairingToken.length > 0) {
                headers["Authorization"] = "Bearer " + config.pairingToken;
              }

              const response = await fetch(url.toString(), {
                method: "POST",
                headers,
                body: offer.sdp
              });

              if (!response.ok) {
                throw new Error(await response.text() || "Failed to establish Realtime transcription.");
              }

              const answerSdp = await response.text();
              await peerConnection.setRemoteDescription({ type: "answer", sdp: answerSdp });

              post({ kind: "event", title: "Session Ready", detail: "Realtime transcription session established." });
            } catch (error) {
              const detail = error && error.message ? error.message : String(error);
              post({ kind: "state", state: "error", detail });
              await cleanup();
            } finally {
              connecting = false;
            }
          }

          async function helmRealtimeDisconnect() {
            if (!peerConnection && !mediaStream && !dataChannel && !personaPlexSocket && !connecting) {
              return;
            }

            await cleanup();
            post({ kind: "state", state: "disconnected", detail: "Live Command stopped." });
          }

          async function helmRealtimeSpeak(payload) {
            if (!currentConfig || !payload || !payload.text) {
              return;
            }

            if (currentConfig.voiceProviderID === "personaplex") {
              try {
                await helmPersonaPlexSpeak(payload);
                return;
              } catch (error) {
                const detail = error && error.message ? error.message : String(error);
                post({
                  kind: "event",
                  title: "PersonaPlex Speech Fallback",
                  detail: detail + " Falling back to helm speech."
                });
              }
            }

            try {
              await playBridgeSpeech(payload, null);
            } catch (error) {
              const detail = error && error.message ? error.message : String(error);
              post({ kind: "event", title: "Speech Output Failed", detail });
            }
          }

          async function playBridgeSpeech(payload, voiceProviderOverride) {
            stopPlayback();
            post({ kind: "state", state: "playing", detail: "Speaking through Command." });
            const shouldResumeListening = payload.resumeListening !== false;

            const url = new URL("/api/voice/speech", currentConfig.bridgeURL);
            const headers = { "Content-Type": "application/json" };
            if (currentConfig.pairingToken && currentConfig.pairingToken.length > 0) {
              headers["Authorization"] = "Bearer " + currentConfig.pairingToken;
            }

            const response = await fetch(url.toString(), {
              method: "POST",
              headers,
              body: JSON.stringify({
                text: payload.text,
                threadId: currentConfig.threadID || undefined,
                backendId: currentConfig.backendID || undefined,
                voiceProviderId: voiceProviderOverride || undefined,
                style: currentConfig.style || undefined
              })
            });

            if (!response.ok) {
              throw new Error(await response.text() || "Failed to fetch spoken response.");
            }

            const blob = await response.blob();
            const objectURL = URL.createObjectURL(blob);
            const audio = new Audio(objectURL);
            playbackAudio = audio;

            audio.onended = () => {
              if (playbackAudio === audio) {
                stopPlayback();
                post({ kind: "playbackFinished" });
                if (shouldResumeListening) {
                  post({ kind: "state", state: "listening", detail: "Listening for the next Command." });
                }
              }
            };

            audio.onerror = () => {
              if (playbackAudio === audio) {
                stopPlayback();
                post({ kind: "event", title: "Speech Output Failed", detail: "Could not play the spoken response." });
                post({ kind: "playbackFinished" });
                if (shouldResumeListening) {
                  post({ kind: "state", state: "listening", detail: "Listening for the next Command." });
                }
              }
            };

            await audio.play();
          }

          function helmRealtimeInterruptOutput() {
            if (stopPlayback()) {
              post({ kind: "playbackInterrupted" });
            }
          }

          window.helmRealtimeConnect = helmRealtimeConnect;
          window.helmRealtimeDisconnect = helmRealtimeDisconnect;
          window.helmRealtimeSpeak = helmRealtimeSpeak;
          window.helmRealtimeInterruptOutput = helmRealtimeInterruptOutput;
        </script>
      </body>
    </html>
    """#

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastPlaybackRequestID: RealtimePlaybackRequest.ID?
        var lastPlaybackStopToken = UUID()
        private let onState: @MainActor (String, String?) -> Void
        private let onEvent: @MainActor (String, String?) -> Void
        private let onPartialTranscript: @MainActor (String) -> Void
        private let onFinalTranscript: @MainActor (String) -> Void
        private let onCommandExchange: @MainActor (RealtimeCommandExchange) -> Void
        private let onCommandFailure: @MainActor (String?, String, String, Int?) -> Void
        private let onPlaybackFinished: @MainActor () -> Void
        private let onPlaybackInterrupted: @MainActor () -> Void

        init(
            onState: @escaping @MainActor (String, String?) -> Void,
            onEvent: @escaping @MainActor (String, String?) -> Void,
            onPartialTranscript: @escaping @MainActor (String) -> Void,
            onFinalTranscript: @escaping @MainActor (String) -> Void,
            onCommandExchange: @escaping @MainActor (RealtimeCommandExchange) -> Void,
            onCommandFailure: @escaping @MainActor (String?, String, String, Int?) -> Void,
            onPlaybackFinished: @escaping @MainActor () -> Void,
            onPlaybackInterrupted: @escaping @MainActor () -> Void
        ) {
            self.onState = onState
            self.onEvent = onEvent
            self.onPartialTranscript = onPartialTranscript
            self.onFinalTranscript = onFinalTranscript
            self.onCommandExchange = onCommandExchange
            self.onCommandFailure = onCommandFailure
            self.onPlaybackFinished = onPlaybackFinished
            self.onPlaybackInterrupted = onPlaybackInterrupted
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let kind = payload["kind"] as? String else {
                return
            }

            switch kind {
            case "state":
                let state = payload["state"] as? String ?? "unknown"
                let detail = payload["detail"] as? String
                Task { @MainActor in
                    onState(state, detail)
                }
            case "event":
                let title = payload["title"] as? String ?? "Realtime Event"
                let detail = payload["detail"] as? String
                Task { @MainActor in
                    onEvent(title, detail)
                }
            case "partialTranscript":
                let text = payload["text"] as? String ?? ""
                Task { @MainActor in
                    onPartialTranscript(text)
                }
            case "finalTranscript":
                let text = payload["text"] as? String ?? ""
                Task { @MainActor in
                    onFinalTranscript(text)
                }
            case "commandExchange":
                let threadID = (payload["threadID"] as? String)?.nilIfEmpty
                let transcript = payload["transcript"] as? String ?? ""
                let acknowledgement = payload["acknowledgement"] as? String ?? "On it."
                let displayResponse = payload["displayResponse"] as? String ?? acknowledgement
                let spokenResponse = (payload["spokenResponse"] as? String)?.nilIfEmpty
                let shouldResumeListening = payload["shouldResumeListening"] as? Bool ?? true
                let backendID = (payload["backendID"] as? String)?.nilIfEmpty
                let backendLabel = (payload["backendLabel"] as? String)?.nilIfEmpty
                let latencyMS = payload["latencyMS"] as? Int

                let exchange = RealtimeCommandExchange(
                    threadId: threadID,
                    transcript: transcript,
                    exchange: VoiceCommandExchange(
                        acknowledgement: acknowledgement,
                        displayResponse: displayResponse,
                        spokenResponse: spokenResponse,
                        shouldResumeListening: shouldResumeListening,
                        backendId: backendID,
                        backendLabel: backendLabel
                    ),
                    latencyMS: latencyMS
                )

                Task { @MainActor in
                    onCommandExchange(exchange)
                }
            case "commandFailure":
                let threadID = (payload["threadID"] as? String)?.nilIfEmpty
                let transcript = payload["transcript"] as? String ?? ""
                let detail = payload["detail"] as? String ?? "I couldn't send that."
                let latencyMS = payload["latencyMS"] as? Int
                Task { @MainActor in
                    onCommandFailure(threadID, transcript, detail, latencyMS)
                }
            case "playbackFinished":
                Task { @MainActor in
                    onPlaybackFinished()
                }
            case "playbackInterrupted":
                Task { @MainActor in
                    onPlaybackInterrupted()
                }
            default:
                break
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
