import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import express from "express";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { IncomingMessage } from "node:http";
import { homedir, networkInterfaces } from "node:os";
import path from "node:path";
import type { Duplex } from "node:stream";
import WebSocket, { WebSocketServer } from "ws";

import type { AgentBackend } from "./agentBackend.js";
import { config } from "./config.js";
import { ClaudeCodeBackend } from "./claudeCodeBackend.js";
import { CodexBackend } from "./codexBackend.js";
import {
  canonicalCodexThreadId,
  deleteCodexThreadReplacement,
  listCodexThreadReplacements,
  recordCodexThreadReplacement,
} from "./codexThreadReplacementRegistry.js";
import {
  codexThreadPreviewForDisplay,
  discoverCodexThread,
  preferredCodexThreadName,
  readCodexThreadLocalTurns,
  resolveCodexThreadByName,
} from "./codexThreadDiscovery.js";
import { HELM_RUNTIME_LAUNCH_SOURCE, isHelmManagedLaunchSource } from "./helmManagedLaunch.js";
import { ManagedTerminalBackend } from "./managedTerminalBackend.js";
import { OpenAIVoiceProvider } from "./openAIVoiceProvider.js";
import { PairingManager } from "./pairingManager.js";
import { PersonaPlexVoiceProvider } from "./personaPlexVoiceProvider.js";
import { RealtimeEventLog } from "./realtimeEventLog.js";
import { RuntimeTracker } from "./runtimeTracker.js";
import {
  canonicalRuntimeThreadId,
  findMatchingLaunchByPID,
  findMatchingLaunchByThreadID,
  isRuntimeRelayAvailable,
  listRuntimeLaunches,
  readRuntimeOutputTail,
  updateRuntimeLaunchThreadId,
  type RuntimeLaunchRecord,
  type RuntimeOutputTail,
} from "./runtimeLaunchRegistry.js";
import { sessionLaunchOptionsForBackend } from "./sessionLaunchConfig.js";
import { captureSimulatorScreenshot, listBootedSimulators } from "./simulatorMirror.js";
import { extractReadableText } from "./threadTextExtraction.js";
import { ThreadControllerRegistry } from "./threadControllerRegistry.js";
import { UnavailableBackend } from "./unavailableBackend.js";
import { resolveWorkspacePath } from "./workspaceRoots.js";
import type {
  ApprovalDecisionRequest,
  ApprovalKind,
  BackendSummary,
  ConversationEvent,
  ControlRequest,
  JSONValue,
  PendingApproval,
  RuntimePhase,
  RuntimeThreadState,
  ServerRequestEvent,
  StartTurnFileAttachment,
  StartTurnImageAttachment,
  TurnDeliveryMode,
  ThreadDetail,
  ThreadDetailItem,
  ThreadDetailTurn,
  ThreadSummary,
  VoiceCommandResponse,
  VoiceCommandRequest,
  VoiceSpeechRequest,
} from "./types.js";
import type { VoiceProvider, VoiceProviderSummary } from "./voiceProvider.js";

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message);
  }
}

const CODEX_THREAD_ID_RE =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

type PendingApprovalRecord = PendingApproval & {
  backendId: string;
  method: string;
};

type CachedThreadSummaryRecord = {
  thread: ThreadSummary;
  lastSeenAt: number;
};

type CachedThreadListRecord = {
  threads: ThreadSummary[];
  updatedAt: number;
};

type CodexThreadRegistryRow = {
  id?: string;
  updated_at?: number;
  source?: string | null;
  cwd?: string | null;
  title?: string | null;
  first_user_message?: string | null;
};

export class BridgeServer {
  private static readonly THREAD_MIRROR_POLL_INTERVAL_MS = 250;
  private static readonly THREAD_MIRROR_RECENT_WINDOW_MS = 10 * 60 * 1000;
  private static readonly THREAD_MIRROR_MAX_THREADS = 8;
  private static readonly CODEX_LAUNCH_THREAD_DRIFT_MIN_MS = 60_000;
  private static readonly CODEX_IMPLICIT_RESUME_CANDIDATE_GAP_MS = 5 * 60_000;
  private static readonly THREAD_LIST_ENRICH_LIMIT = 6;
  private static readonly THREAD_DETAIL_BROADCAST_DEBOUNCE_MS = 20;
  private static readonly THREAD_DETAIL_BURST_DELAYS_MS = [0, 120, 320, 900];
  private static readonly THREAD_DETAIL_ACTIVE_POLL_REFRESH_INTERVAL_MS = 750;
  private static readonly THREAD_DETAIL_POLL_REFRESH_INTERVAL_MS = 2_000;
  private static readonly RUNTIME_TAIL_THREAD_DETAIL_REFRESH_INTERVAL_MS = 250;
  private static readonly THREAD_DETAIL_RESPONSE_FRESH_WAIT_MS = 450;
  private static readonly THREAD_DETAIL_STREAM_RESPONSE_FRESH_WAIT_MS = 1_500;
  private static readonly BACKEND_STARTUP_CONNECT_TIMEOUT_MS = 2_500;
  private static readonly RUNTIME_TAIL_REALTIME_POLL_INTERVAL_MS = 100;
  private static readonly THREAD_DETAIL_MAX_TURNS = 16;
  private static readonly THREAD_DETAIL_MAX_ITEMS = 96;
  private static readonly THREAD_DETAIL_MAX_ITEMS_PER_TURN = 24;
  private static readonly THREAD_DETAIL_MAX_TEXT_CHARS = 4_000;
  private static readonly THREAD_DETAIL_MAX_MESSAGE_TEXT_CHARS = 64_000;
  private static readonly THREAD_DETAIL_MAX_TERMINAL_TEXT_CHARS = 12_000;
  private static readonly THREAD_DETAIL_WS_MAX_TURNS = 8;
  private static readonly THREAD_DETAIL_WS_MAX_ITEMS = 48;
  private static readonly THREAD_DETAIL_WS_MAX_TEXT_CHARS = 1_000;
  private static readonly THREAD_DETAIL_WS_MAX_MESSAGE_TEXT_CHARS = 8_000;
  private static readonly THREAD_DETAIL_WS_MAX_TERMINAL_TEXT_CHARS = 8_000;
  private static readonly THREAD_DETAIL_WS_MAX_REASONING_TEXT_CHARS = 4_000;
  private static readonly THREAD_ACTIVE_DISCOVERY_GRACE_MS = 2 * 60 * 1000;
  private static readonly THREAD_RECENT_DISCOVERY_GRACE_MS = 30 * 1000;
  private static readonly CODEX_RECENT_ARCHIVED_DESKTOP_PROMOTION_WINDOW_MS = 45 * 60 * 1000;
  private static readonly TURN_IMAGE_MAX_ATTACHMENTS = 4;
  private static readonly TURN_IMAGE_MAX_BYTES = 5 * 1024 * 1024;
  private static readonly TURN_IMAGE_TOTAL_MAX_BYTES = 16 * 1024 * 1024;
  private static readonly TURN_FILE_MAX_ATTACHMENTS = 4;
  private static readonly TURN_FILE_MAX_BYTES = 4 * 1024 * 1024;
  private static readonly TURN_FILE_TOTAL_MAX_BYTES = 12 * 1024 * 1024;
  private static readonly MAX_WS_OUTBOUND_MESSAGE_BYTES = 3_500_000;

  private readonly app = express();
  private readonly httpServer = createServer(this.app);
  private readonly wsServer = new WebSocketServer({ noServer: true });
  private readonly nativeVoiceProxyServer = new WebSocketServer({ noServer: true });
  private readonly backends = new Map<string, AgentBackend>();
  private readonly defaultBackendId: string;
  private readonly clients = new Set<WebSocket>();
  private readonly realtimeEvents = new RealtimeEventLog();
  private readonly controllers = new ThreadControllerRegistry();
  private readonly runtime = new RuntimeTracker();
  private readonly pendingApprovals = new Map<string, PendingApprovalRecord>();
  private readonly pairing = new PairingManager(
    config.bridgePairingFile,
    config.bridgePairingToken
  );
  private readonly threadBackendIds = new Map<string, string>();
  private readonly voiceProviders = new Map<string, VoiceProvider>();
  private readonly defaultVoiceProviderId: string;
  private readonly mirroredThreadDetailCache = new Map<string, string>();
  private readonly mirroredThreadDetailObjectCache = new Map<string, ThreadDetail>();
  private mirroredThreadListCache: string | null = null;
  private readonly discoveredThreadCache = new Map<string, CachedThreadSummaryRecord>();
  private readonly threadDetailBroadcastTimers = new Map<string, NodeJS.Timeout>();
  private readonly threadDetailBroadcastInFlight = new Map<string, Promise<void>>();
  private readonly threadDetailReadInFlight = new Map<string, Promise<ThreadDetail | null>>();
  private readonly threadDetailPollRefreshAt = new Map<string, number>();
  private readonly runtimeTailDetailRefreshAttemptAt = new Map<string, number>();
  private threadListCache: CachedThreadListRecord | null = null;
  private threadListRefreshInFlight: Promise<ThreadSummary[]> | null = null;
  private threadMirrorPollTimer: NodeJS.Timeout | null = null;
  private runtimeTailRealtimePollTimer: NodeJS.Timeout | null = null;
  private readonly runtimeTailUpdatedAtByLaunchKey = new Map<string, number>();
  private threadMirrorPollInFlight = false;

  constructor() {
    const codex = new CodexBackend(config.codexAppServerUrl);
    this.backends.set(codex.summary.id, codex);
    for (const backend of this.futureBackends()) {
      this.backends.set(backend.summary.id, backend);
    }
    this.defaultBackendId = codex.summary.id;
    const openAI = new OpenAIVoiceProvider();
    const personaPlex = new PersonaPlexVoiceProvider();
    this.voiceProviders.set(openAI.summary.id, openAI);
    this.voiceProviders.set(personaPlex.summary.id, personaPlex);
    this.defaultVoiceProviderId = this.resolveDefaultVoiceProviderId();
  }

  async start(): Promise<void> {
    const pairingStatus = await this.pairing.initialize();
    await Promise.all(Array.from(this.backends.values()).map(async (backend) => {
      backend.on("event", (event: ConversationEvent) => {
        this.handleConversationEvent(backend.summary.id, event);
      });

      backend.on("serverRequest", (request: ServerRequestEvent) => {
        this.handleServerRequest(backend.summary.id, request);
      });

      try {
        await this.connectBackendAtStartup(backend);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.warn(`[bridge] backend ${backend.summary.id} unavailable at startup: ${message}`);
      }
    }));
    this.refreshRuntimePresenceFromLaunches();
    this.installMiddleware();
    this.installRoutes();
    this.installSockets();
    this.startThreadMirrorPolling();
    this.startRuntimeTailRealtimePolling();

    await new Promise<void>((resolve) => {
      this.httpServer.listen(config.bridgePort, config.bridgeHost, () => {
        resolve();
      });
    });

    console.log(`[bridge] pairing token file: ${pairingStatus.filePath}`);
    console.log(
      `[bridge] local pairing info: http://127.0.0.1:${config.bridgePort}/api/pairing`
    );
    for (const url of this.externalBridgeURLs()) {
      console.log(`[bridge] remote bridge url: ${url}`);
    }
  }

  private installMiddleware(): void {
    this.app.use(express.json({ limit: "24mb" }));
    this.app.use((req, res, next) => {
      if (this.isPublicRoute(req.path)) {
        next();
        return;
      }

      const auth = this.authenticateRequest(req);
      if (!auth.ok) {
        res.status(401).json({ error: "Missing or invalid helm pairing token" });
        return;
      }

      next();
    });
  }

  private installRoutes(): void {
    this.app.get("/health", async (_req, res) => {
      res.json({
        ok: true,
        bridgePort: config.bridgePort,
        codexEndpoint: config.codexAppServerUrl,
        defaultBackendId: this.defaultBackendId,
        defaultVoiceProviderId: this.defaultVoiceProviderId,
        backends: this.backendSummaries(),
        voiceProviders: await this.voiceProviderSummaries(),
      });
    });

    this.app.get("/api/simulator/booted", async (req, res) => {
      try {
        const simulators = await listBootedSimulators();
        const requestedUDID =
          typeof req.query.udid === "string" ? req.query.udid.trim() : "";
        const selected =
          (requestedUDID
            ? simulators.find((simulator) => simulator.udid === requestedUDID)
            : null) ?? simulators[0] ?? null;

        res.json({
          simulators,
          selected,
        });
      } catch (error) {
        this.handleError(
          res,
          error instanceof HttpError
            ? error
            : new HttpError(
                500,
                `Failed to list booted simulators: ${error instanceof Error ? error.message : String(error)}`
              ));
      }
    });

    this.app.get("/api/simulator/screenshot", async (req, res) => {
      try {
        const simulators = await listBootedSimulators();
        const requestedUDID =
          typeof req.query.udid === "string" ? req.query.udid.trim() : "";
        const selected =
          (requestedUDID
            ? simulators.find((simulator) => simulator.udid === requestedUDID)
            : null) ?? simulators[0] ?? null;

        if (!selected) {
          throw new HttpError(404, "No booted simulator is available.");
        }

        const screenshot = await captureSimulatorScreenshot(selected.udid);
        res.setHeader("Cache-Control", "no-store, max-age=0");
        res.setHeader("Content-Type", "image/png");
        res.setHeader("X-Helm-Simulator-Udid", selected.udid);
        res.send(screenshot);
      } catch (error) {
        this.handleError(
          res,
          error instanceof HttpError
            ? error
            : new HttpError(
                500,
                `Failed to capture simulator screenshot: ${error instanceof Error ? error.message : String(error)}`
              )
        );
      }
    });

    this.app.get("/simulator", (req, res) => {
      const token = this.requestToken(req);
      if (!token) {
        res.status(401).type("text/plain").send("Missing helm pairing token.");
        return;
      }

      const requestedUDID =
        typeof req.query.udid === "string" ? req.query.udid.trim() : "";
      const selectedUDIDLiteral = JSON.stringify(requestedUDID);
      const tokenLiteral = JSON.stringify(token);

      res.type("html").send(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Helm Simulator Mirror</title>
    <style>
      :root { color-scheme: dark; }
      body {
        margin: 0;
        background: #0b0d10;
        color: #f5f7fa;
        font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif;
        display: grid;
        grid-template-rows: auto 1fr;
        min-height: 100vh;
      }
      header {
        padding: 10px 14px;
        border-bottom: 1px solid rgba(255,255,255,0.08);
        display: flex;
        gap: 12px;
        align-items: center;
        justify-content: space-between;
      }
      #meta {
        opacity: 0.8;
        font-size: 12px;
      }
      main {
        display: grid;
        place-items: center;
        padding: 14px;
      }
      img {
        max-width: min(100%, 540px);
        max-height: calc(100vh - 72px);
        width: auto;
        height: auto;
        border-radius: 18px;
        box-shadow: 0 18px 60px rgba(0,0,0,0.45);
        background: #11161b;
      }
      .error {
        color: #ff8a80;
      }
    </style>
  </head>
  <body>
    <header>
      <div>
        <div><strong>Helm Simulator Mirror</strong></div>
        <div id="meta">Loading…</div>
      </div>
      <div id="status"></div>
    </header>
    <main>
      <img id="frame" alt="Booted iOS Simulator" />
    </main>
    <script>
      const token = ${tokenLiteral};
      const requestedUDID = ${selectedUDIDLiteral};
      const frame = document.getElementById("frame");
      const meta = document.getElementById("meta");
      const status = document.getElementById("status");
      let activeUDID = requestedUDID;

      async function refreshMeta() {
        const url = new URL("/api/simulator/booted", window.location.origin);
        url.searchParams.set("token", token);
        if (activeUDID) url.searchParams.set("udid", activeUDID);
        const response = await fetch(url, { cache: "no-store" });
        const payload = await response.json();
        if (!response.ok) throw new Error(payload.error || "Failed to load simulator state.");
        if (!payload.selected) throw new Error("No booted simulator is available.");
        activeUDID = payload.selected.udid;
        meta.textContent = payload.selected.name + " • " + payload.selected.runtime + " • " + payload.selected.udid;
      }

      async function refreshFrame() {
        const url = new URL("/api/simulator/screenshot", window.location.origin);
        url.searchParams.set("token", token);
        if (activeUDID) url.searchParams.set("udid", activeUDID);
        url.searchParams.set("ts", String(Date.now()));
        frame.src = url.toString();
      }

      async function tick() {
        try {
          await refreshMeta();
          await refreshFrame();
          status.textContent = "live";
          status.className = "";
        } catch (error) {
          status.textContent = error instanceof Error ? error.message : String(error);
          status.className = "error";
        }
      }

      tick();
      setInterval(tick, 500);
    </script>
  </body>
</html>`);
    });

    this.app.get("/api/backends", (_req, res) => {
      res.json({
        defaultBackendId: this.defaultBackendId,
        backends: this.backendSummaries(),
      });
    });

    this.app.get("/api/voice/providers", async (_req, res) => {
      res.json({
        defaultVoiceProviderId: this.defaultVoiceProviderId,
        providers: await this.voiceProviderSummaries(),
      });
    });

    this.app.get("/api/voice/providers/:providerId/bootstrap", async (req, res) => {
      try {
        const backend = this.backendForCommandRequest(req.query);
        const style = this.normalizeVoiceStyle(
          typeof req.query.style === "string"
            ? (req.query.style as VoiceCommandRequest["style"])
            : undefined
        );
        const provider = this.voiceProviders.get(req.params.providerId);
        if (!provider) {
          throw new HttpError(404, `Voice provider '${req.params.providerId}' is not available in helm`);
        }
        const summary = await provider.getSummary();
        const bootstrap = await provider.describeBootstrap({
          voiceProviderId: summary.id,
          style,
          threadId:
            typeof req.query.threadId === "string"
              ? this.canonicalThreadId(req.query.threadId)
              : undefined,
          backendId: backend.summary.id,
        });

        res.json({
          provider: summary,
          backend: backend.summary,
          bootstrap,
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/voice/providers/personaplex/assets/:assetName", async (req, res) => {
      try {
        if (!config.personaPlexBaseURL) {
          throw new HttpError(501, "PersonaPlex is not configured.");
        }

        const assetName = String(req.params.assetName ?? "").trim();
        if (!["decoderWorker.min.js", "decoderWorker.min.wasm"].includes(assetName)) {
          throw new HttpError(404, "Unsupported PersonaPlex asset");
        }

        const baseURL = new URL(config.personaPlexBaseURL);
        const assetURL = new URL(`/assets/${assetName}`, baseURL);
        const headers = new Headers();
        if (config.personaPlexAuthToken) {
          headers.set("Authorization", `Bearer ${config.personaPlexAuthToken}`);
        }

        const upstream = await fetch(assetURL, {
          method: "GET",
          headers,
          redirect: "follow",
        });

        if (!upstream.ok) {
          throw new HttpError(
            upstream.status,
            `PersonaPlex asset fetch failed with ${upstream.status} ${upstream.statusText}`
          );
        }

        const contentType =
          upstream.headers.get("content-type")
          ?? (assetName.endsWith(".wasm") ? "application/wasm" : "application/javascript; charset=utf-8");
        const body = Buffer.from(await upstream.arrayBuffer());
        res.setHeader("Content-Type", contentType);
        res.setHeader("Cache-Control", "no-store");
        res.send(body);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/pairing", (req, res) => {
      const loopback = this.isLoopbackRequest(req);
      if (!loopback && !this.authenticateRequest(req).ok) {
        res.status(401).json({ error: "Missing or invalid helm pairing token" });
        return;
      }

      res.json({
        pairing: this.describePairing(loopback),
      });
    });

    this.app.get("/api/threads", async (_req, res) => {
      try {
        const threads = await this.listThreadsForResponse();
        res.json({ threads });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/threads/archived", async (_req, res) => {
      try {
        const threads = await this.listArchivedThreadsForResponse();
        res.json({ threads });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/runtime", (_req, res) => {
      this.refreshRuntimePresenceFromLaunches();
      res.json({
        threads: this.runtime.list(),
      });
    });

    this.app.get("/api/session-launch/options", (req, res) => {
      try {
        const backend = this.backendForCreateRequest({
          backendId: typeof req.query.backendId === "string" ? req.query.backendId : undefined,
        });
        res.json({
          options: sessionLaunchOptionsForBackend(backend.summary.id),
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/fs/directory-suggestions", async (req, res) => {
      try {
        const prefix = typeof req.query.prefix === "string" ? req.query.prefix : "";
        res.json({
          directories: await listDirectorySuggestions(prefix),
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/fs/file-suggestions", async (req, res) => {
      try {
        const cwd = typeof req.query.cwd === "string" ? req.query.cwd : "";
        const prefix = typeof req.query.prefix === "string" ? req.query.prefix : "";
        res.json({
          files: await listFileTagSuggestions(cwd, prefix),
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/skills/suggestions", async (req, res) => {
      try {
        const prefix = typeof req.query.prefix === "string" ? req.query.prefix : "";
        const cwd = typeof req.query.cwd === "string" ? req.query.cwd : "";
        res.json({
          skills: await listSkillSuggestions(prefix, cwd),
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads", async (req, res) => {
      try {
        const backend = this.backendForCreateRequest(req.body);
        const result = await backend.startThread({
          cwd: typeof req.body?.cwd === "string" ? req.body.cwd : undefined,
          model: typeof req.body?.model === "string" ? req.body.model : undefined,
          baseInstructions:
            typeof req.body?.baseInstructions === "string" ? req.body.baseInstructions : undefined,
          launchMode:
            req.body?.launchMode === "managedShell" || req.body?.launchMode === "sharedThread"
              ? req.body.launchMode
              : undefined,
          reasoningEffort:
            typeof req.body?.reasoningEffort === "string" ? req.body.reasoningEffort : undefined,
          codexFastMode:
            typeof req.body?.codexFastMode === "boolean" ? req.body.codexFastMode : undefined,
          claudeContextMode:
            req.body?.claudeContextMode === "1m" || req.body?.claudeContextMode === "normal"
              ? req.body.claudeContextMode
              : undefined,
        });
        const threadId = this.threadIdFromStartThreadResult(result);
        const detail = threadId
          ? await this.readNormalizedThreadDetailCoalesced(threadId, null, { includeLiveRuntimeTail: true })
          : null;
        this.invalidateThreadListCache();
        res.json({
          threadId,
          thread: detail,
          result,
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/codex/bootstrap-shell-thread", async (req, res) => {
      try {
        const backend = this.backendForId("codex");
        if (!(backend instanceof CodexBackend)) {
          throw new HttpError(501, "Codex backend is not available for shell bootstrap.");
        }

        const result = await backend.bootstrapManagedShellThread({
          cwd: typeof req.body?.cwd === "string" ? req.body.cwd : undefined,
          model: typeof req.body?.model === "string" ? req.body.model : undefined,
          baseInstructions:
            typeof req.body?.baseInstructions === "string" ? req.body.baseInstructions : undefined,
        });
        res.json(result);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/codex/threads/:threadId/ensure-managed", async (req, res) => {
      try {
        const ensured = await this.openCanonicalThread(req.params.threadId, {
          launchManagedShell: Boolean(req.body?.launchManagedShell),
          preferVisibleLaunch: false,
        });
        res.json(ensured);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/codex/threads/ensure-managed", async (req, res) => {
      try {
        const threadTarget = String(req.body?.threadTarget ?? "").trim();
        if (!threadTarget) {
          throw new HttpError(400, "Missing threadTarget");
        }

        const ensured = await this.openCanonicalThreadTarget(threadTarget, {
          launchManagedShell: Boolean(req.body?.launchManagedShell),
          preferVisibleLaunch: false,
        });
        res.json({
          requestedTarget: threadTarget,
          ...ensured,
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/open", async (req, res) => {
      try {
        const opened = await this.openCanonicalThread(req.params.threadId, {
          launchManagedShell: true,
          preferVisibleLaunch: true,
        });
        const cached = this.liveCachedThreadDetail(opened.threadId);
        const summary = cached ? this.threadSummaryFromDetail(cached) : this.cachedThreadSummary(opened.threadId);
        const detail =
          cached
          ?? (summary
            ? this.placeholderThreadDetailFromSummary(summary, {
              includeLiveRuntimeTail: true,
            })
            : null);
        void this.readNormalizedThreadDetailCoalesced(opened.threadId, summary, {
          includeLiveRuntimeTail: true,
        })
          .then((freshDetail) => {
            if (freshDetail) {
              this.publishThreadDetailIfChanged(freshDetail);
            }
          })
          .catch((error) => {
            const message = error instanceof Error ? error.message : String(error);
            console.error(`[bridge] thread detail refresh after open failed: ${message}`);
          });
        if (opened.replaced || opened.launched) {
          this.invalidateThreadListCache();
        }
        res.json({
          threadId: opened.threadId,
          previousThreadId: opened.previousThreadId,
          replaced: opened.replaced,
          launched: opened.launched,
          thread: detail,
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/threads/:threadId", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const preferFresh =
          this.isTruthyQueryValue(req.query.fresh) ||
          this.isTruthyQueryValue(req.query.stream);
        const detail =
          await this.readNormalizedThreadDetailForResponse(canonicalThreadId, {
            includeLiveRuntimeTail: true,
            preferFresh,
          })
          ?? this.liveCachedThreadDetail(canonicalThreadId);
        res.json({ thread: detail });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/archive", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const backend = this.backendForThread(canonicalThreadId);
        if (backend instanceof CodexBackend) {
          await backend.archiveThread(canonicalThreadId);
        }
        this.retireReplacedThreadState(canonicalThreadId);
        this.invalidateThreadListCache();
        res.json({ archived: true, threadId: canonicalThreadId });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/unarchive", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        this.unarchiveCodexThreadInStateDatabase(canonicalThreadId);
        this.invalidateThreadListCache();
        res.json({ archived: false, threadId: canonicalThreadId });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/turns", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const text = String(req.body?.text ?? "").trim();
        const imageAttachments = await this.imageAttachmentsFromRequest(req.body);
        const fileAttachments = await this.fileAttachmentsFromRequest(req.body);
        if (!text && imageAttachments.length === 0 && fileAttachments.length === 0) {
          res.status(400).json({ error: "Missing text or attachment" });
          return;
        }

        this.ensureThreadControlForCommand(canonicalThreadId, req.body);
        const deliveryMode = this.turnDeliveryModeFromRequest(req.body);
        const backend = this.backendForThread(canonicalThreadId);
        console.log(
          `[bridge] turn/send request thread=${canonicalThreadId} backend=${backend.summary.id} mode=${deliveryMode} textBytes=${Buffer.byteLength(text, "utf8")} images=${imageAttachments.length} files=${fileAttachments.length}`
        );
        const result = await backend.startTurn(canonicalThreadId, text, {
          deliveryMode,
          imageAttachments,
          fileAttachments,
        });
        const resultRecord = result && typeof result === "object" && !Array.isArray(result)
          ? result as { mode?: unknown; threadId?: unknown }
          : {};
        console.log(
          `[bridge] turn/send result thread=${canonicalThreadId} backend=${backend.summary.id} mode=${typeof resultRecord.mode === "string" ? resultRecord.mode : "unknown"} deliveredThread=${typeof resultRecord.threadId === "string" ? resultRecord.threadId : canonicalThreadId}`
        );
        this.scheduleThreadDetailBroadcastBurst(canonicalThreadId);
        res.json(result);
      } catch (error) {
        console.warn(
          `[bridge] turn/send failed thread=${req.params.threadId}: ${error instanceof Error ? error.message : String(error)}`
        );
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/interrupt", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        this.ensureThreadControlForCommand(canonicalThreadId, req.body);
        const backend = this.backendForThread(canonicalThreadId);
        const result = await backend.interruptTurn(canonicalThreadId);
        this.scheduleThreadDetailBroadcastBurst(canonicalThreadId);
        res.json(result);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/input", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const input = this.terminalInputSequenceFromRequest(req.body);
        if (!input) {
          res.status(400).json({ error: "Unsupported terminal input" });
          return;
        }

        this.ensureThreadControlForCommand(canonicalThreadId, req.body);
        const backend = this.backendForThread(canonicalThreadId);
        const result = await backend.sendInput(canonicalThreadId, input);
        this.scheduleThreadDetailBroadcastBurst(canonicalThreadId);
        res.json(result);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/name", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const name = String(req.body?.name ?? "").trim();
        if (!name) {
          res.status(400).json({ error: "Missing name" });
          return;
        }

        const backend = this.backendForThread(canonicalThreadId);
        const result = await backend.renameThread(canonicalThreadId, name);
        this.invalidateThreadListCache();
        res.json(result);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/control/take", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        const controller = this.claimThreadControl(canonicalThreadId, req.body as ControlRequest);
        void this.broadcastControlChange(canonicalThreadId);
        res.json({ controller });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/threads/:threadId/control/release", async (req, res) => {
      try {
        const canonicalThreadId = this.canonicalThreadId(req.params.threadId);
        this.releaseThreadControl(canonicalThreadId, req.body as ControlRequest);
        void this.broadcastControlChange(canonicalThreadId);
        res.json({ released: true });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/control/heartbeat", (req, res) => {
      try {
        const identity = this.requireClientIdentity(req.body as ControlRequest);
        const threadIds: string[] = Array.isArray(req.body?.threadIds)
          ? req.body.threadIds
              .map((value: unknown) => String(value ?? "").trim())
              .filter((value: string) => value.length > 0)
          : [];

        const controllers = threadIds
          .map((threadId: string) => {
            const controller = this.controllers.touch(threadId, identity.clientId);
            if (!controller) {
              return null;
            }

            return {
              threadId,
              controller,
            };
          })
          .filter(
            (
              value
            ): value is { threadId: string; controller: NonNullable<ThreadSummary["controller"]> } => value !== null
          );

        res.json({ controllers });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/approvals/:approvalId/decision", (req, res) => {
      try {
        const body = req.body as ApprovalDecisionRequest;
        const decision = String(body?.decision ?? "").trim() as ApprovalDecisionRequest["decision"];
        if (!["accept", "acceptForSession", "decline", "cancel"].includes(decision)) {
          throw new HttpError(400, "Unsupported approval decision");
        }

        const approval = this.pendingApprovals.get(req.params.approvalId);
        if (!approval) {
          throw new HttpError(404, "Approval request not found");
        }

        if (!approval.canRespond) {
          throw new HttpError(501, "This approval type is not wired for mobile response yet");
        }

        const backend = this.backendForId(approval.backendId);
        this.ensureBackendSupportsBridgeApprovals(backend);
        backend.respond(approval.requestId, {
          decision,
        });
        this.pendingApprovals.delete(approval.requestId);
        const thread = this.runtime.resolveApproval(approval.requestId, decision);
        if (thread) {
          this.runtime.recordEvent({
            threadId: thread.threadId,
            turnId: approval.turnId,
            itemId: approval.itemId,
            method: `${approval.method}/resolved`,
            title: `Approval ${decision}`,
            detail: approval.title,
            phase: decision === "accept" || decision === "acceptForSession" ? "running" : decision === "cancel" ? "blocked" : "idle",
          });
          this.broadcastRuntimeThread(thread.threadId);
        }

        res.json({ ok: true });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/voice/command", async (req, res) => {
      try {
        const body = req.body as VoiceCommandRequest;
        const text = body.text?.trim();
        if (!body.threadId || !text) {
          res.status(400).json({ error: "threadId and text are required" });
          return;
        }

        const canonicalThreadId = this.canonicalThreadId(body.threadId);
        this.ensureThreadControlForCommand(canonicalThreadId, body);
        const backend = this.backendForThread(canonicalThreadId);
        this.ensureBackendSupportsVoiceCommand(backend);
        const result = await backend.startTurn(canonicalThreadId, text);
        const response = this.buildVoiceCommandResponse({
          style: body.style,
          backend: backend.summary,
          result,
        });
        res.json(response);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post("/api/voice/speech", async (req, res) => {
      try {
        const body = req.body as VoiceSpeechRequest;
        const text = String(body?.text ?? "").trim();
        if (!text) {
          res.status(400).json({ error: "Missing text" });
          return;
        }

        const backend = this.backendForCommandRequest(body);
        if (backend.summary.command.voiceOutput === "none") {
          throw new HttpError(501, `${backend.summary.label} does not currently expose spoken output through helm`);
        }

        const provider = await this.voiceProviderForRequest(body);
        const summary = await provider.getSummary();
        const speech = await provider.createSpeechAudio(text);
        res.setHeader("X-Helm-Backend-Id", backend.summary.id);
        res.setHeader("X-Helm-Backend-Voice-Output", backend.summary.command.voiceOutput);
        res.setHeader("X-Helm-Voice-Provider-Id", summary.id);
        res.setHeader("Content-Type", speech.contentType);
        res.send(speech.audio);
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.get("/api/realtime/client-secret", async (req, res) => {
      try {
        const style = typeof req.query.style === "string" ? req.query.style : undefined;
        const backend = this.backendForCommandRequest(req.query);
        this.ensureBackendSupportsRealtimeVoice(backend);
        const provider = await this.voiceProviderForRequest({
          voiceProviderId: typeof req.query.voiceProviderId === "string" ? req.query.voiceProviderId : undefined,
          style,
        });
        const summary = await provider.getSummary();
        const secret = await provider.createClientSecret({
          instructions: this.buildVoiceInstructions(provider, style),
        });
        const secretPayload =
          secret && typeof secret === "object" && !Array.isArray(secret)
            ? secret
            : { session: secret ?? null };
        res.json({
          ...secretPayload,
          backend: backend.summary,
          voiceProvider: summary,
        });
      } catch (error) {
        this.handleError(res, error);
      }
    });

    this.app.post(
      "/api/realtime/session",
      express.text({ type: ["application/sdp", "text/plain"] }),
      async (req, res) => {
        try {
          const sdp = typeof req.body === "string" ? req.body.trim() : "";
          if (!sdp) {
            res.status(400).json({ error: "Missing SDP offer" });
            return;
          }

          const style = typeof req.query.style === "string" ? req.query.style : undefined;
          const mode =
            req.query.mode === "transcription" ? "transcription" : "realtime";
          const backend = this.backendForCommandRequest(req.query);
          this.ensureBackendSupportsRealtimeVoice(backend);
          const provider = await this.voiceProviderForRequest({
            voiceProviderId: typeof req.query.voiceProviderId === "string" ? req.query.voiceProviderId : undefined,
            style,
          });
          const summary = await provider.getSummary();

          const answer = await provider.createRealtimeSessionAnswer(sdp, {
            mode,
            instructions: this.buildVoiceInstructions(provider, style),
          });

          res.setHeader("X-Helm-Voice-Provider-Id", summary.id);
          res.type("application/sdp").send(answer);
        } catch (error) {
          this.handleError(res, error);
        }
      }
    );
  }

  private buildVoiceCommandResponse(input: {
    style: VoiceCommandRequest["style"];
    backend: BackendSummary;
    result?: JSONValue;
  }): VoiceCommandResponse {
    const style = this.normalizeVoiceStyle(input.style);
    const acknowledgement = this.acknowledgementForStyle(style);
    const spokenResponse =
      input.backend.command.voiceOutput === "none" || input.backend.command.voiceOutput === "providerNative"
        ? null
        : acknowledgement;

    return {
      acknowledgement,
      displayResponse: acknowledgement,
      spokenResponse,
      shouldResumeListening: true,
      backend: input.backend,
      result: input.result,
    };
  }

  private normalizeVoiceStyle(style: VoiceCommandRequest["style"]): NonNullable<VoiceCommandRequest["style"]> {
    switch (style) {
      case "concise":
      case "formal":
      case "jarvis":
      case "codex":
        return style;
      default:
        return "codex";
    }
  }

  private acknowledgementForStyle(style: NonNullable<VoiceCommandRequest["style"]>): string {
    switch (style) {
      case "concise":
        return "On it.";
      case "formal":
        return "Understood. I’m on it.";
      case "jarvis":
        return "Right away.";
      case "codex":
      default:
        return "On it.";
    }
  }

  private describePairing(includeSecret: boolean): ReturnType<PairingManager["describe"]> & {
    suggestedBridgeURLs: string[];
    setupURL?: string;
  } {
    const pairing = this.pairing.describe(includeSecret);
    const suggestedBridgeURLs = this.pairingBridgeURLs();
    const primaryBridgeURL = suggestedBridgeURLs[0];
    const setupURL =
      pairing.token && primaryBridgeURL
        ? this.buildPairingSetupURL(primaryBridgeURL, pairing.token, pairing.bridgeId)
        : undefined;

    return {
      ...pairing,
      suggestedBridgeURLs,
      setupURL,
    };
  }

  private resolveDefaultVoiceProviderId(): string {
    const configured = config.defaultVoiceProviderId;
    if (this.voiceProviders.has(configured)) {
      return configured;
    }

    return "openai-realtime";
  }

  private async voiceProviderSummaries(): Promise<VoiceProviderSummary[]> {
    const summaries = await Promise.all(
      Array.from(this.voiceProviders.values()).map((provider) => provider.getSummary())
    );

    return summaries.sort(
      (lhs, rhs) => Number(rhs.available) - Number(lhs.available) || lhs.label.localeCompare(rhs.label)
    );
  }

  private async voiceProviderForRequest(input: {
    voiceProviderId?: unknown;
    style?: unknown;
  }): Promise<VoiceProvider> {
    const requestedId = typeof input.voiceProviderId === "string" ? input.voiceProviderId.trim() : "";
    const providerId = requestedId || this.defaultVoiceProviderId;
    const provider = this.voiceProviders.get(providerId);
    if (!provider) {
      throw new HttpError(404, `Voice provider '${providerId}' is not available in helm`);
    }

    const summary = await provider.getSummary();
    if (!summary.available) {
      throw new HttpError(
        501,
        summary.availabilityDetail ?? `${summary.label} is not available yet`
      );
    }

    return provider;
  }

  private buildVoiceInstructions(
    provider: VoiceProvider,
    style: VoiceCommandRequest["style"] | string | undefined
  ): string {
    if (provider instanceof OpenAIVoiceProvider) {
      return provider.buildInstructions(style);
    }

    return config.voiceConfirmationInstructions;
  }

  private installSockets(): void {
    this.httpServer.on("upgrade", (request, socket, head) => {
      void this.handleUpgrade(request, socket, head);
    });

    this.wsServer.on("connection", (socket, request) => {
      this.clients.add(socket);
      this.refreshRuntimePresenceFromLaunches();
      const runtimeThreads = this.runtime.list();
      const requestURL = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
      const resumeAfter = this.resumeSequenceFromURL(requestURL);
      const resume = this.realtimeEvents.describeResume(resumeAfter);

      socket.send(
        JSON.stringify({
          type: "bridge.ready",
          payload: {
            message: "Connected to helm bridge",
            bridgeId: this.pairing.describe(false).bridgeId,
            resumedFromSequence: resume.canResume ? resumeAfter : null,
            latestSequence: resume.latestSequence,
            oldestRetainedSequence: resume.oldestRetainedSequence,
          },
        })
      );

      if (resume.canResume) {
        for (const event of resume.events) {
          socket.send(event.text);
        }
      } else {
        socket.send(
          JSON.stringify({
            type: "helm.runtime.snapshot",
            payload: {
              threads: runtimeThreads,
            },
          })
        );

        if (this.threadListCache) {
          socket.send(
            JSON.stringify({
              type: "helm.threads.snapshot",
              payload: {
                threads: this.withControllerMetadata(this.threadListCache.threads),
              },
            })
          );
        }
      }

      void this.refreshThreadListCache().catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        console.error(`[bridge] websocket thread-list refresh failed: ${message}`);
      });

      socket.on("close", () => {
        this.clients.delete(socket);
      });
    });

    this.nativeVoiceProxyServer.on("connection", (downstream, request) => {
      const proxiedRequest = request as IncomingMessage & {
        helmVoiceProxyTarget?: {
          url: string;
          headers?: Record<string, string>;
          protocols?: string[];
        };
      };
      const target = proxiedRequest.helmVoiceProxyTarget;
      if (!target) {
        downstream.close(1011, "Missing proxy target");
        return;
      }

      const upstream = new WebSocket(target.url, target.protocols ?? [], {
        headers: target.headers,
      });

      let upstreamClosed = false;
      let downstreamClosed = false;

      const closeDownstream = (code: number, reason?: string) => {
        if (downstreamClosed) {
          return;
        }
        downstreamClosed = true;
        downstream.close(code, reason);
      };

      const closeUpstream = (code?: number, reason?: Buffer) => {
        if (upstreamClosed) {
          return;
        }
        upstreamClosed = true;
        upstream.close(code, reason?.toString("utf8"));
      };

      upstream.on("message", (data, isBinary) => {
        if (downstream.readyState === WebSocket.OPEN) {
          downstream.send(data, { binary: isBinary });
        }
      });

      downstream.on("message", (data, isBinary) => {
        if (upstream.readyState === WebSocket.OPEN) {
          upstream.send(data, { binary: isBinary });
        }
      });

      upstream.on("close", (code, reason) => {
        closeDownstream(code, reason.toString("utf8"));
      });

      downstream.on("close", (code, reason) => {
        closeUpstream(code, reason);
      });

      upstream.on("error", (error) => {
        console.error(`[bridge] PersonaPlex proxy error: ${error.message}`);
        closeDownstream(1011, "Upstream voice proxy failed");
      });

      downstream.on("error", () => {
        closeUpstream();
      });
    });
  }

  private startThreadMirrorPolling(): void {
    if (this.threadMirrorPollTimer) {
      clearInterval(this.threadMirrorPollTimer);
    }

    this.threadMirrorPollTimer = setInterval(() => {
      void this.pollMirroredThreads();
    }, BridgeServer.THREAD_MIRROR_POLL_INTERVAL_MS);

    void this.pollMirroredThreads();
  }

  private startRuntimeTailRealtimePolling(): void {
    if (this.runtimeTailRealtimePollTimer) {
      clearInterval(this.runtimeTailRealtimePollTimer);
    }

    this.runtimeTailRealtimePollTimer = setInterval(() => {
      this.pollRuntimeTailsForRealtimeBroadcast();
    }, BridgeServer.RUNTIME_TAIL_REALTIME_POLL_INTERVAL_MS);

    this.pollRuntimeTailsForRealtimeBroadcast();
  }

  private pollRuntimeTailsForRealtimeBroadcast(): void {
    if (this.clients.size === 0) {
      return;
    }

    const seenKeys = new Set<string>();
    for (const launch of listRuntimeLaunches()) {
      if (!isRuntimeRelayAvailable(launch) || !launch.outputTailPath) {
        continue;
      }

      const tail = readRuntimeOutputTail(launch);
      if (!tail) {
        continue;
      }

      const key = `${launch.runtime}:${launch.pid}:${launch.outputTailPath}`;
      seenKeys.add(key);
      if (this.runtimeTailUpdatedAtByLaunchKey.get(key) === tail.updatedAt) {
        continue;
      }

      this.runtimeTailUpdatedAtByLaunchKey.set(key, tail.updatedAt);
      this.publishRuntimeTailDetailIfChanged(launch, tail);
    }

    for (const key of this.runtimeTailUpdatedAtByLaunchKey.keys()) {
      if (!seenKeys.has(key)) {
        this.runtimeTailUpdatedAtByLaunchKey.delete(key);
      }
    }
  }

  private publishRuntimeTailDetailIfChanged(
    launch: RuntimeLaunchRecord,
    tail: RuntimeOutputTail
  ): void {
    const backendId = this.backendIdForRuntime(launch.runtime);
    if (!backendId) {
      return;
    }

    const threadId =
      canonicalRuntimeThreadId(launch.runtime, launch.threadId)
      ?? (this.backends.has(launch.runtime) ? `${launch.runtime}:${launch.pid}` : null);
    if (!threadId) {
      return;
    }

    const cached = this.cachedThreadDetail(threadId);
    const summary =
      cached
        ? this.threadSummaryFromDetail(cached)
        : this.cachedThreadSummary(threadId)
          ?? this.threadSummaryFromRuntimeLaunch(launch, threadId, backendId, tail);

    this.broadcastThreadDetail(
      this.placeholderThreadDetailFromSummary(summary, {
        includeLiveRuntimeTail: true,
      })
    );
    this.scheduleRuntimeTailThreadDetailRefresh(threadId);
  }

  private async pollMirroredThreads(): Promise<void> {
    if (this.clients.size === 0) {
      return;
    }

    if (this.threadMirrorPollInFlight) {
      return;
    }

    this.threadMirrorPollInFlight = true;
    try {
      this.refreshRuntimePresenceFromLaunches();
      const threads = await this.refreshThreadListCache();
      const activeThreadIDs = new Set(threads.map((thread) => thread.id));
      for (const cachedThreadID of this.mirroredThreadDetailCache.keys()) {
        if (!activeThreadIDs.has(cachedThreadID)) {
          this.mirroredThreadDetailCache.delete(cachedThreadID);
          this.mirroredThreadDetailObjectCache.delete(cachedThreadID);
          this.threadDetailPollRefreshAt.delete(cachedThreadID);
          this.runtimeTailDetailRefreshAttemptAt.delete(cachedThreadID);
        }
      }

      const candidates = this.threadMirrorCandidates(threads);
      await Promise.all(
        candidates.map((thread) => this.broadcastThreadDetailForSummarySafely(thread))
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[bridge] thread mirroring poll failed: ${message}`);
    } finally {
      this.threadMirrorPollInFlight = false;
    }
  }

  private threadMirrorCandidates(threads: ThreadSummary[]): ThreadSummary[] {
    const now = Date.now();
    return threads
      .filter((thread) => {
        if (thread.status === "running") {
          return true;
        }

        if (this.controllers.get(thread.id)) {
          return true;
        }

        if (this.runtime.get(thread.id)) {
          return true;
        }

        return now - thread.updatedAt <= BridgeServer.THREAD_MIRROR_RECENT_WINDOW_MS;
      })
      .sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt)
      .slice(0, BridgeServer.THREAD_MIRROR_MAX_THREADS);
  }

  private async broadcastThreadDetailIfChanged(summary: ThreadSummary): Promise<void> {
    const canonicalThreadId = this.canonicalThreadId(summary.id);
    const cached = this.liveCachedThreadDetail(canonicalThreadId);
    if (cached) {
      this.publishThreadDetailIfChanged(cached);
    } else {
      this.publishThreadDetailIfChanged(
        this.placeholderThreadDetailFromSummary(summary, {
          includeLiveRuntimeTail: true,
        })
      );
    }

    if (
      cached
      && !this.shouldRefreshPolledThreadDetail(summary, cached, canonicalThreadId)
    ) {
      return;
    }

    const detail = await this.readNormalizedThreadDetailCoalesced(summary.id, summary, {
      includeLiveRuntimeTail: true,
    });
    if (!detail) {
      return;
    }

    this.threadDetailPollRefreshAt.set(canonicalThreadId, Date.now());
    this.publishThreadDetailIfChanged(detail);
  }

  private shouldRefreshPolledThreadDetail(
    summary: ThreadSummary,
    cached: ThreadDetail,
    threadId: string
  ): boolean {
    const lastRefreshAt = this.threadDetailPollRefreshAt.get(threadId) ?? 0;
    const hasNonLiveTurn = cached.turns.some((turn) => turn.id !== `live-tail-${threadId}`);
    const refreshInterval =
      summary.status === "running" || !hasNonLiveTurn
        ? BridgeServer.THREAD_DETAIL_ACTIVE_POLL_REFRESH_INTERVAL_MS
        : BridgeServer.THREAD_DETAIL_POLL_REFRESH_INTERVAL_MS;
    if (Date.now() - lastRefreshAt < refreshInterval) {
      return false;
    }

    if (!hasNonLiveTurn) {
      return true;
    }

    if (summary.updatedAt > cached.updatedAt) {
      return true;
    }

    return summary.status === "running";
  }

  private async broadcastThreadDetailForSummarySafely(summary: ThreadSummary): Promise<void> {
    const canonicalThreadId = this.canonicalThreadId(summary.id);
    const existing = this.threadDetailBroadcastInFlight.get(canonicalThreadId);
    if (existing) {
      try {
        await existing;
      } catch {
        // The owning broadcast logs failures; duplicate waiters just coalesce.
      }
      return;
    }

    const broadcast = this.broadcastThreadDetailIfChanged(summary);
    this.threadDetailBroadcastInFlight.set(canonicalThreadId, broadcast);
    try {
      await broadcast;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[bridge] thread detail broadcast failed: ${message}`);
    } finally {
      if (this.threadDetailBroadcastInFlight.get(canonicalThreadId) === broadcast) {
        this.threadDetailBroadcastInFlight.delete(canonicalThreadId);
      }
    }
  }

  private async broadcastThreadDetailForId(threadId: string): Promise<void> {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const cached = this.liveCachedThreadDetail(canonicalThreadId);
    const detail = await this.readNormalizedThreadDetailCoalesced(
      canonicalThreadId,
      cached ? this.threadSummaryFromDetail(cached) : null,
      {
        includeLiveRuntimeTail: true,
      }
    );
    if (!detail) {
      return;
    }

    this.threadDetailPollRefreshAt.set(canonicalThreadId, Date.now());
    this.publishThreadDetailIfChanged(detail);
  }

  private scheduleRuntimeTailThreadDetailRefresh(threadId: string): void {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const now = Date.now();
    const lastAttemptAt = this.runtimeTailDetailRefreshAttemptAt.get(canonicalThreadId) ?? 0;
    if (now - lastAttemptAt < BridgeServer.RUNTIME_TAIL_THREAD_DETAIL_REFRESH_INTERVAL_MS) {
      return;
    }

    this.runtimeTailDetailRefreshAttemptAt.set(canonicalThreadId, now);
    void this.broadcastThreadDetailForIdSafely(canonicalThreadId);
  }

  private async broadcastThreadDetailForIdSafely(threadId: string): Promise<void> {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const existing = this.threadDetailBroadcastInFlight.get(canonicalThreadId);
    if (existing) {
      try {
        await existing;
      } catch {
        // The owning broadcast logs failures; duplicate waiters just coalesce.
      }
      return;
    }

    const broadcast = this.broadcastThreadDetailForId(canonicalThreadId);
    this.threadDetailBroadcastInFlight.set(canonicalThreadId, broadcast);
    try {
      await broadcast;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[bridge] thread detail broadcast failed: ${message}`);
    } finally {
      if (this.threadDetailBroadcastInFlight.get(canonicalThreadId) === broadcast) {
        this.threadDetailBroadcastInFlight.delete(canonicalThreadId);
      }
    }
  }

  private publishThreadDetailIfChanged(detail: ThreadDetail): void {
    this.mergeThreadDetailIntoThreadListCache(detail);

    const serialized = JSON.stringify(detail);
    if (this.mirroredThreadDetailCache.get(detail.id) === serialized) {
      if (!this.mirroredThreadDetailObjectCache.has(detail.id)) {
        this.mirroredThreadDetailObjectCache.set(detail.id, detail);
      }
      return;
    }

    this.mirroredThreadDetailCache.set(detail.id, serialized);
    this.mirroredThreadDetailObjectCache.set(detail.id, detail);
    this.broadcast({
      type: "helm.thread.detail",
      payload: {
        thread: detail,
      },
    });
  }

  private broadcastThreadDetail(detail: ThreadDetail): void {
    this.broadcast({
      type: "helm.thread.detail",
      payload: {
        thread: detail,
      },
    });
  }

  private scheduleThreadDetailBroadcast(threadId: string): void {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const existing = this.threadDetailBroadcastTimers.get(canonicalThreadId);
    if (existing) {
      clearTimeout(existing);
    }

    const timer = setTimeout(() => {
      this.threadDetailBroadcastTimers.delete(canonicalThreadId);
      void this.broadcastThreadDetailForIdSafely(canonicalThreadId);
    }, BridgeServer.THREAD_DETAIL_BROADCAST_DEBOUNCE_MS);
    timer.unref?.();
    this.threadDetailBroadcastTimers.set(canonicalThreadId, timer);
  }

  private scheduleThreadDetailBroadcastBurst(threadId: string): void {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    for (const delay of BridgeServer.THREAD_DETAIL_BURST_DELAYS_MS) {
      const timer = setTimeout(() => {
        void this.broadcastThreadDetailForIdSafely(canonicalThreadId);
      }, delay);
      timer.unref?.();
    }
  }

  private cachedThreadDetail(threadId: string): ThreadDetail | null {
    const cached = this.mirroredThreadDetailObjectCache.get(threadId);
    if (cached) {
      return cached;
    }

    const serialized = this.mirroredThreadDetailCache.get(threadId);
    if (!serialized) {
      return null;
    }

    try {
      const parsed = JSON.parse(serialized);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return null;
      }

      const detail = parsed as ThreadDetail;
      this.mirroredThreadDetailObjectCache.set(threadId, detail);
      return detail;
    } catch {
      return null;
    }
  }

  private liveCachedThreadDetail(threadId: string): ThreadDetail | null {
    const cached = this.cachedThreadDetail(threadId);
    if (!cached) {
      return null;
    }

    return this.withLiveRuntimeTail(cached, cached.backendId);
  }

  private threadSummaryFromDetail(
    detail: ThreadDetail,
    fallbackThread: ThreadSummary | null = null
  ): ThreadSummary {
    const status = fallbackThread
      ? this.preferredThreadStatus(detail.status, fallbackThread.status, detail.updatedAt || fallbackThread.updatedAt)
      : detail.status;
    return {
      id: detail.id,
      name: detail.name,
      preview: this.mergedThreadPreview(
        this.threadPreviewFromDetail(detail),
        status,
        fallbackThread?.preview ?? null,
        fallbackThread?.name ?? detail.name ?? null
      ),
      cwd: detail.cwd,
      workspacePath: detail.workspacePath ?? null,
      status,
      updatedAt: detail.updatedAt,
      sourceKind: detail.sourceKind,
      launchSource: detail.launchSource,
      backendId: detail.backendId,
      backendLabel: detail.backendLabel,
      backendKind: detail.backendKind,
      controller: this.controllers.get(detail.id) ?? null,
    };
  }

  private async listThreadsForResponse(): Promise<ThreadSummary[]> {
    const refresh = this.refreshThreadListCache();
    const cached = this.threadListCache
      ? this.withControllerMetadata(this.threadListCache.threads)
      : null;
    if (!cached) {
      return await refresh;
    }

    void refresh.catch((error) => {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`[bridge] background thread-list refresh failed: ${message}`);
    });
    return cached;
  }

  private async listArchivedThreadsForResponse(): Promise<ThreadSummary[]> {
    const archivedThreads = await this.withWorkspacePaths(
      this.readRecentCodexThreadRows(300, { archived: true })
        .map((row) => this.threadSummaryFromCodexRegistryRow(row))
        .filter((thread): thread is ThreadSummary => thread !== null)
    );

    return this.withControllerMetadata(archivedThreads);
  }

  private async refreshThreadListCache(): Promise<ThreadSummary[]> {
    if (this.threadListRefreshInFlight) {
      return await this.threadListRefreshInFlight;
    }

    const refresh = (async () => {
      const discoveredThreads = this.withControllerMetadata(await this.listThreadsAcrossBackends());
      const threads = await this.enrichThreadSummaries(
        this.withControllerMetadata(await this.promoteLiveArchivedCodexThreads(discoveredThreads))
      );
      this.threadListCache = {
        threads,
        updatedAt: Date.now(),
      };
      this.publishThreadListIfChanged(threads);
      return threads;
    })();

    this.threadListRefreshInFlight = refresh;
    try {
      return await refresh;
    } finally {
      if (this.threadListRefreshInFlight === refresh) {
        this.threadListRefreshInFlight = null;
      }
    }
  }

  private invalidateThreadListCache(): void {
    this.threadListCache = null;
  }

  private mergeThreadDetailIntoThreadListCache(detail: ThreadDetail): void {
    if (!this.threadListCache) {
      return;
    }

    const existingIndex = this.threadListCache.threads.findIndex((thread) => thread.id === detail.id);
    const threads = [...this.threadListCache.threads];
    const existingThread = existingIndex >= 0 ? threads[existingIndex] : null;
    const summary = existingThread && this.isLiveTailOnlyThreadDetail(detail)
      ? {
        ...existingThread,
        status: this.preferredThreadStatus(detail.status, existingThread.status, existingThread.updatedAt),
        controller: this.controllers.get(detail.id) ?? existingThread.controller ?? null,
      }
      : this.threadSummaryFromDetail(detail, existingThread);
    if (existingIndex >= 0) {
      threads[existingIndex] = {
        ...threads[existingIndex]!,
        ...summary,
      };
    } else {
      threads.push(summary);
    }

    this.threadListCache = {
      threads: threads.sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt),
      updatedAt: Date.now(),
    };
    this.publishThreadListIfChanged(this.threadListCache.threads);
  }

  private isLiveTailOnlyThreadDetail(detail: ThreadDetail): boolean {
    return detail.turns.length > 0 && detail.turns.every((turn) => turn.id.startsWith("live-tail-"));
  }

  private publishThreadListIfChanged(threads: ThreadSummary[]): void {
    const threadsWithControllers = this.withControllerMetadata(threads);
    const serialized = JSON.stringify(threadsWithControllers);
    if (this.mirroredThreadListCache === serialized) {
      return;
    }

    this.mirroredThreadListCache = serialized;
    this.broadcast({
      type: "helm.threads.snapshot",
      payload: {
        threads: threadsWithControllers,
      },
    });
  }

  private async enrichThreadSummaries(threads: ThreadSummary[]): Promise<ThreadSummary[]> {
    if (threads.length === 0) {
      return threads;
    }

    const enriched = [...threads];
    const candidates = enriched
      .map((thread, index) => ({
        thread,
        index,
        cachedDetail: this.liveCachedThreadDetail(thread.id),
      }))
      .filter(({ thread, cachedDetail }) => cachedDetail || this.threadSummaryNeedsOpportunisticDetailRefresh(thread))
      .slice(0, BridgeServer.THREAD_LIST_ENRICH_LIMIT);

    await Promise.all(
      candidates.map(async ({ thread, index, cachedDetail }) => {
        const detail = cachedDetail;
        if (!detail) {
          if (this.threadSummaryNeedsOpportunisticDetailRefresh(thread)) {
            const fetchedDetail = await this.readNormalizedThreadDetail(thread.id, thread);
            if (fetchedDetail) {
              enriched[index] = await this.enrichThreadSummaryWithDetail(thread, fetchedDetail);
              return;
            }
          }
          this.scheduleThreadDetailBroadcast(thread.id);
          return;
        }

        enriched[index] = await this.enrichThreadSummaryWithDetail(thread, detail);
      })
    );

    return enriched.sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt);
  }

  private threadSummaryNeedsOpportunisticDetailRefresh(thread: ThreadSummary): boolean {
    const preview = this.previewText(thread.preview);
    if (!preview || this.isGenericThreadPreview(preview)) {
      return true;
    }

    const name = this.previewText(thread.name);
    if (!name) {
      return true;
    }

    return preview === name;
  }

  private async promoteLiveArchivedCodexThreads(threads: ThreadSummary[]): Promise<ThreadSummary[]> {
    const existingThreadIDs = new Set(threads.map((thread) => thread.id));
    const replacedThreadIDs = new Set(
      listCodexThreadReplacements("codex").map((record) => record.oldThreadId)
    );
    const promoted: ThreadSummary[] = [];

    for (const row of this.readRecentCodexThreadRows(200, { archived: true })) {
      if (!row.id || existingThreadIDs.has(row.id) || replacedThreadIDs.has(row.id)) {
        continue;
      }

      const runtime = this.runtime.get(row.id);
      const launch = findMatchingLaunchByThreadID("codex", row.id);
      const hasLiveLaunch = isRuntimeRelayAvailable(launch);
      const updatedAt = this.normalizeCodexRegistryUpdatedAt(row.updated_at) || Date.now();
      const isRecentlyUpdatedDesktopThread =
        this.codexArchivedRowUsesSharedDesktopSurface(row)
        && Date.now() - updatedAt <= BridgeServer.CODEX_RECENT_ARCHIVED_DESKTOP_PROMOTION_WINDOW_MS;
      if (!hasLiveLaunch && !this.runtimeThreadLooksLive(runtime) && !isRecentlyUpdatedDesktopThread) {
        continue;
      }

      const summary = this.threadSummaryFromCodexRegistryRow(row);
      if (!summary) {
        continue;
      }

      existingThreadIDs.add(row.id);
      promoted.push({
        ...summary,
        status: isRecentlyUpdatedDesktopThread
          ? this.preferredThreadStatus("running", summary.status, updatedAt)
          : this.preferredRuntimeStatus(runtime, summary.status),
        updatedAt: Math.max(summary.updatedAt, runtime?.lastUpdatedAt ?? 0, launch?.launchedAt ?? 0),
        launchSource: hasLiveLaunch ? HELM_RUNTIME_LAUNCH_SOURCE : summary.launchSource,
      });
    }

    if (promoted.length === 0) {
      return threads;
    }

    return await this.withWorkspacePaths([...threads, ...promoted]);
  }

  private runtimeThreadLooksLive(runtime: RuntimeThreadState | null): boolean {
    if (!runtime) {
      return false;
    }

    if (runtime.phase === "running" || runtime.phase === "waitingApproval" || runtime.phase === "blocked") {
      return true;
    }

    if (runtime.currentTurnId || runtime.pendingApprovals.length > 0) {
      return true;
    }

    return runtime.recentEvents.length > 0
      && Date.now() - runtime.lastUpdatedAt <= BridgeServer.THREAD_ACTIVE_DISCOVERY_GRACE_MS;
  }

  private preferredRuntimeStatus(runtime: RuntimeThreadState | null, fallback: string): string {
    switch (runtime?.phase) {
      case "running":
      case "waitingApproval":
        return "running";
      case "blocked":
        return "blocked";
      case "completed":
      case "idle":
        return fallback === "unknown" ? "idle" : fallback;
      default:
        return fallback;
    }
  }

  private codexArchivedRowUsesSharedDesktopSurface(row: CodexThreadRegistryRow): boolean {
    const source = this.codexThreadSource(row);
    return source === "appserver" || source === "vscode";
  }

  private async enrichThreadSummaryWithDetail(
    thread: ThreadSummary,
    detail: ThreadDetail
  ): Promise<ThreadSummary> {
    const cwd = detail.cwd || thread.cwd;
    const workspacePath =
      detail.workspacePath
      ?? thread.workspacePath
      ?? await resolveWorkspacePath(cwd);

    return {
      ...thread,
      name: detail.name ?? thread.name,
      preview: this.mergedThreadPreview(
        this.threadPreviewFromDetail(detail),
        this.preferredThreadStatus(detail.status, thread.status, detail.updatedAt || thread.updatedAt),
        thread.preview,
        detail.name ?? thread.name ?? null
      ),
      cwd,
      workspacePath: workspacePath || null,
      status: this.preferredThreadStatus(detail.status, thread.status, detail.updatedAt || thread.updatedAt),
      updatedAt: this.normalizeThreadUpdatedAt(detail.updatedAt || thread.updatedAt),
      sourceKind: detail.sourceKind ?? thread.sourceKind,
      launchSource: detail.launchSource ?? thread.launchSource ?? null,
    };
  }

  private async readNormalizedThreadDetailForResponse(
    threadId: string,
    options: {
      includeLiveRuntimeTail?: boolean;
      preferFresh?: boolean;
    } = {}
  ): Promise<ThreadDetail | null> {
    const cached = this.liveCachedThreadDetail(threadId);
    const summary = cached
      ? this.threadSummaryFromDetail(cached)
      : this.cachedThreadSummary(threadId)
        ?? await this.discoverLocalCodexThreadSummary(threadId);
    const fallbackPromise = this.fallbackThreadDetailForResponse(threadId, summary, options, cached);
    const read = this.readNormalizedThreadDetailCoalesced(
      threadId,
      summary,
      options
    )
      .then((detail) => {
        if (detail) {
          this.publishThreadDetailIfChanged(detail);
        }
        return detail;
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        console.warn(`[bridge] thread detail refresh failed for ${threadId}: ${message}`);
        return null;
      });

    const fallback = await fallbackPromise;
    if (fallback) {
      const freshWaitMS = options.preferFresh
        ? BridgeServer.THREAD_DETAIL_STREAM_RESPONSE_FRESH_WAIT_MS
        : BridgeServer.THREAD_DETAIL_RESPONSE_FRESH_WAIT_MS;
      const detail = await Promise.race<ThreadDetail | null>([
        read,
        new Promise<null>((resolve) => {
          const timer = setTimeout(
            () => resolve(null),
            freshWaitMS
          );
          timer.unref?.();
        }),
      ]);
      if (detail) {
        return BridgeServer.shouldPreferFallbackThreadDetail(detail, fallback)
          ? fallback
          : detail;
      }
      return fallback;
    }

    return await read;
  }

  private static shouldPreferFallbackThreadDetail(
    detail: ThreadDetail,
    fallback: ThreadDetail
  ): boolean {
    return BridgeServer.materialThreadTurnCount(detail) == 0
      && BridgeServer.materialThreadTurnCount(fallback) > 0;
  }

  private static materialThreadTurnCount(detail: ThreadDetail): number {
    return detail.turns.filter((turn) => !turn.id.startsWith("live-tail-")).length;
  }

  private async fallbackThreadDetailForResponse(
    threadId: string,
    summary: ThreadSummary | null,
    options: {
      includeLiveRuntimeTail?: boolean;
    } = {},
    cached: ThreadDetail | null = null
  ): Promise<ThreadDetail | null> {
    if (cached && BridgeServer.materialThreadTurnCount(cached) > 0) {
      return cached;
    }

    if (!summary) {
      return cached;
    }

    const localFallback = await this.codexLocalThreadDetailFallback(threadId, summary, options);
    if (localFallback) {
      return localFallback;
    }

    if (cached) {
      return cached;
    }

    return this.placeholderThreadDetailFromSummary(summary, options);
  }

  private isTruthyQueryValue(value: unknown): boolean {
    const candidate = Array.isArray(value) ? value[0] : value;
    if (typeof candidate !== "string") {
      return false;
    }

    switch (candidate.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    default:
      return false;
    }
  }

  private async readNormalizedThreadDetailCoalesced(
    threadId: string,
    summary: ThreadSummary | null = null,
    options: {
      includeLiveRuntimeTail?: boolean;
    } = {}
  ): Promise<ThreadDetail | null> {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const key = [
      canonicalThreadId,
      options.includeLiveRuntimeTail ? "tail" : "detail",
      summary?.updatedAt ?? "nosummary",
    ].join(":");
    const existing = this.threadDetailReadInFlight.get(key);
    if (existing) {
      return await existing;
    }

    const read = this.readNormalizedThreadDetail(canonicalThreadId, summary, options);
    this.threadDetailReadInFlight.set(key, read);
    try {
      return await read;
    } finally {
      if (this.threadDetailReadInFlight.get(key) === read) {
        this.threadDetailReadInFlight.delete(key);
      }
    }
  }

  private cachedThreadSummary(threadId: string): ThreadSummary | null {
    return this.threadListCache?.threads.find((thread) => thread.id === threadId) ?? null;
  }

  private placeholderThreadDetailFromSummary(
    summary: ThreadSummary,
    options: {
      includeLiveRuntimeTail?: boolean;
    } = {}
  ): ThreadDetail {
    const backend = this.backendForId(summary.backendId);
    const placeholder: ThreadDetail = {
      id: summary.id,
      name: summary.name,
      cwd: summary.cwd,
      workspacePath: summary.workspacePath ?? null,
      status: summary.status,
      updatedAt: this.normalizeThreadUpdatedAt(summary.updatedAt),
      sourceKind: summary.sourceKind,
      launchSource: summary.launchSource ?? null,
      backendId: backend.summary.id,
      backendLabel: backend.summary.label,
      backendKind: backend.summary.kind,
      command: backend.summary.command,
      affordances: this.threadAffordancesForThread(backend.summary, summary),
      turns: [],
    };

    return options.includeLiveRuntimeTail
      ? this.withLiveRuntimeTail(placeholder, backend.summary.id)
      : placeholder;
  }

  private async codexLocalThreadDetailFallback(
    threadId: string,
    summary: ThreadSummary,
    options: {
      includeLiveRuntimeTail?: boolean;
    } = {}
  ): Promise<ThreadDetail | null> {
    const backend = this.backendForId(summary.backendId);
    if (backend.summary.id !== "codex") {
      return null;
    }

    const localTurns = await this.codexLocalThreadTurns(threadId);
    if (localTurns.length === 0) {
      return null;
    }

    const detail = this.normalizeThreadDetail(
      {
        thread: {
          id: summary.id,
          name: summary.name,
          preview: summary.preview,
          cwd: summary.cwd,
          status: summary.status,
          updatedAt: this.normalizeThreadUpdatedAt(summary.updatedAt),
          sourceKind: summary.sourceKind,
          launchSource: summary.launchSource ?? null,
          turns: localTurns,
        },
      },
      backend.summary,
      summary
    );
    if (!detail) {
      return null;
    }

    const workspacePath = summary.workspacePath ?? await resolveWorkspacePath(detail.cwd);
    const detailWithWorkspace = {
      ...detail,
      workspacePath: workspacePath || null,
    };

    return options.includeLiveRuntimeTail
      ? this.withLiveRuntimeTail(detailWithWorkspace, backend.summary.id)
      : detailWithWorkspace;
  }

  private async codexLocalThreadTurns(threadId: string): Promise<JSONValue[]> {
    return await readCodexThreadLocalTurns(threadId);
  }

  private async readNormalizedThreadDetail(
    threadId: string,
    summary: ThreadSummary | null = null,
    options: {
      includeLiveRuntimeTail?: boolean;
    } = {}
  ): Promise<ThreadDetail | null> {
    const backend = this.backendForThread(threadId);
    const threadSummary =
      summary
      ?? this.threadListCache?.threads.find((thread) => thread.id === threadId)
      ?? await this.discoverLocalCodexThreadSummary(threadId)
      ?? this.withControllerMetadata(await this.withWorkspacePaths(await backend.listThreads())).find(
        (thread) => thread.id === threadId
      )
      ?? null;
    let result: JSONValue | undefined;
    try {
      result = await backend.readThread(threadId);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (threadSummary) {
        console.warn(
          `[bridge] thread detail read failed for ${threadId}; using discovered summary: ${message}`
        );
        return this.placeholderThreadDetailFromSummary(threadSummary, options);
      }
      throw error;
    }

    const detail = this.normalizeThreadDetail(result, backend.summary, threadSummary);
    if (!detail) {
      if (threadSummary) {
        return this.placeholderThreadDetailFromSummary(threadSummary, options);
      }
      return null;
    }

    const workspacePath = threadSummary?.workspacePath ?? await resolveWorkspacePath(detail.cwd);
    const detailWithWorkspace = {
      ...detail,
      workspacePath: workspacePath || null,
    };

    if (!options.includeLiveRuntimeTail) {
      return detailWithWorkspace;
    }

    return this.withLiveRuntimeTail(detailWithWorkspace, backend.summary.id);
  }

  private async discoverLocalCodexThreadSummary(threadId: string): Promise<ThreadSummary | null> {
    const backend = this.backendForThread(threadId);
    if (backend.summary.id !== "codex") {
      return null;
    }

    const summary = await discoverCodexThread(threadId);
    if (!summary) {
      return null;
    }

    return this.withControllerMetadata([
      {
        ...summary,
        workspacePath: summary.workspacePath ?? await resolveWorkspacePath(summary.cwd) ?? null,
      },
    ])[0] ?? null;
  }

  private async connectBackendAtStartup(backend: AgentBackend): Promise<void> {
    let timer: NodeJS.Timeout | null = null;
    try {
      await Promise.race([
        backend.connect(),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            reject(new Error(
              `startup connect timed out after ${BridgeServer.BACKEND_STARTUP_CONNECT_TIMEOUT_MS}ms`
            ));
          }, BridgeServer.BACKEND_STARTUP_CONNECT_TIMEOUT_MS);
          timer.unref?.();
        }),
      ]);
    } finally {
      if (timer) {
        clearTimeout(timer);
      }
    }
  }

  private async handleUpgrade(
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer
  ): Promise<void> {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

    if (url.pathname === "/ws/mobile") {
      const auth = this.authenticateUpgradeRequest(request, url);
      if (!auth.ok) {
        this.rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }

      this.wsServer.handleUpgrade(request, socket, head, (websocket) => {
        this.wsServer.emit("connection", websocket, request);
      });
      return;
    }

    if (url.pathname === "/ws/voice/personaplex") {
      const auth = this.authenticateUpgradeRequest(request, url);
      if (!auth.ok) {
        this.rejectUpgrade(socket, 401, "Unauthorized");
        return;
      }

      try {
        const provider = this.voiceProviders.get("personaplex");
        if (!(provider instanceof PersonaPlexVoiceProvider)) {
          throw new HttpError(404, "PersonaPlex voice provider is not installed");
        }

        const summary = await provider.getSummary();
        if (!summary.available) {
          throw new HttpError(501, summary.availabilityDetail ?? "PersonaPlex is not available");
        }

        const backend = this.backendForCommandRequest({
          backendId: url.searchParams.get("backendId"),
          threadId: url.searchParams.get("threadId"),
        });
        const style = this.normalizeVoiceStyle(
          typeof url.searchParams.get("style") === "string"
            ? (url.searchParams.get("style") as VoiceCommandRequest["style"])
            : undefined
        );
        const proxyTarget = await provider.createNativeProxyTarget(
          {
            voiceProviderId: summary.id,
            style,
            threadId:
              typeof url.searchParams.get("threadId") === "string"
                ? this.canonicalThreadId(url.searchParams.get("threadId")!)
                : null,
            backendId: backend.summary.id,
          },
          url.searchParams
        );

        if (!proxyTarget) {
          throw new HttpError(501, "PersonaPlex did not return a native proxy target");
        }

        (
          request as IncomingMessage & {
            helmVoiceProxyTarget?: {
              url: string;
              headers?: Record<string, string>;
              protocols?: string[];
            };
          }
        ).helmVoiceProxyTarget = proxyTarget;

        this.nativeVoiceProxyServer.handleUpgrade(request, socket, head, (websocket) => {
          this.nativeVoiceProxyServer.emit("connection", websocket, request);
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Voice proxy unavailable";
        const status = error instanceof HttpError ? error.status : 502;
        this.rejectUpgrade(socket, status, message);
      }
      return;
    }

    socket.destroy();
  }

  private rejectUpgrade(socket: Duplex, status: number, message: string): void {
    const reason =
      status === 401 ? "Unauthorized" :
      status === 404 ? "Not Found" :
      status === 501 ? "Not Implemented" :
      status === 502 ? "Bad Gateway" :
      "Error";
    socket.write(
      `HTTP/1.1 ${status} ${reason}\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n${message}`
    );
    socket.destroy();
  }

  private tokenForUpgradeRequest(request: IncomingMessage, url: URL): string | null {
    const authHeader = Array.isArray(request.headers.authorization)
      ? request.headers.authorization[0]
      : request.headers.authorization;
    return (
      this.extractBearerToken(authHeader) ??
      this.extractBearerToken(
        typeof url.searchParams.get("token") === "string"
          ? `Bearer ${url.searchParams.get("token")}`
          : undefined
      )
    );
  }

  private authenticateUpgradeRequest(request: IncomingMessage, url: URL) {
    return this.pairing.authenticate({
      token: this.tokenForUpgradeRequest(request, url),
      method: request.method ?? "GET",
      path: this.pathForUpgradeAuth(url),
      clientId: this.requestHeaderValue(request.headers["x-helm-client-id"]),
      clientName: this.requestHeaderValue(request.headers["x-helm-client-name"]),
      clientKey: this.requestHeaderValue(request.headers["x-helm-client-key"]),
      signature: this.requestHeaderValue(request.headers["x-helm-client-signature"]),
      timestamp: this.numericHeaderValue(request.headers["x-helm-client-timestamp"]),
      nonce: this.requestHeaderValue(request.headers["x-helm-client-nonce"]),
    });
  }

  private authenticateRequest(req: express.Request) {
    return this.pairing.authenticate({
      token: this.requestToken(req),
      method: req.method,
      path: this.pathForExpressAuth(req),
      clientId: this.requestHeaderValue(req.headers["x-helm-client-id"]),
      clientName: this.requestHeaderValue(req.headers["x-helm-client-name"]),
      clientKey: this.requestHeaderValue(req.headers["x-helm-client-key"]),
      signature: this.requestHeaderValue(req.headers["x-helm-client-signature"]),
      timestamp: this.numericHeaderValue(req.headers["x-helm-client-timestamp"]),
      nonce: this.requestHeaderValue(req.headers["x-helm-client-nonce"]),
    });
  }

  private requestToken(req: express.Request): string | null {
    const headerToken = this.extractBearerToken(req.headers.authorization);
    if (headerToken) {
      return headerToken;
    }

    const queryToken = typeof req.query.token === "string" ? req.query.token.trim() : "";
    return queryToken.length > 0 ? queryToken : null;
  }

  private requestHeaderValue(value: string | string[] | undefined): string | null {
    if (Array.isArray(value)) {
      return typeof value[0] === "string" && value[0].trim().length > 0
        ? value[0].trim()
        : null;
    }

    return typeof value === "string" && value.trim().length > 0 ? value.trim() : null;
  }

  private numericHeaderValue(value: string | string[] | undefined): number | null {
    const parsed = Number(this.requestHeaderValue(value));
    return Number.isFinite(parsed) ? parsed : null;
  }

  private pathForExpressAuth(req: express.Request): string {
    const candidate = typeof req.originalUrl === "string" && req.originalUrl.length > 0
      ? req.originalUrl
      : req.url;
    return candidate || req.path || "/";
  }

  private pathForUpgradeAuth(url: URL): string {
    return `${url.pathname}${url.search}`;
  }

  private resumeSequenceFromURL(url: URL): number | null {
    const raw = url.searchParams.get("resumeAfter");
    if (!raw) {
      return null;
    }

    const parsed = Number(raw);
    return Number.isFinite(parsed) ? Math.max(0, Math.trunc(parsed)) : null;
  }

  private handleConversationEvent(backendId: string, event: ConversationEvent): void {
    this.broadcast({
      type: "codex.event",
      payload: {
        backendId,
        event,
      },
    });

    const threadId = this.extractStringByKeys(event.params, ["threadId", "conversationId"]) ?? this.extractNestedThreadId(event.params);
    if (!threadId) {
      return;
    }

    this.threadBackendIds.set(threadId, backendId);

    const normalized = this.normalizeConversationEvent(event.method, event.params);
    this.runtime.recordEvent({
      threadId,
      turnId: normalized.turnId,
      itemId: normalized.itemId,
      method: event.method,
      title: normalized.title,
      detail: normalized.detail,
      phase: normalized.phase,
    });
    this.broadcastRuntimeThread(threadId);
    this.scheduleThreadDetailBroadcast(threadId);
  }

  private handleServerRequest(backendId: string, request: ServerRequestEvent): void {
    if (request.method === "item/commandExecution/requestApproval" || request.method === "item/fileChange/requestApproval" || request.method === "item/permissions/requestApproval") {
      const approval = this.buildPendingApproval(backendId, request);
      this.pendingApprovals.set(approval.requestId, approval);
      this.runtime.addApproval(approval);
      this.runtime.recordEvent({
        threadId: approval.threadId,
        turnId: approval.turnId,
        itemId: approval.itemId,
        method: request.method,
        title: approval.title,
        detail: approval.detail,
        phase: "waitingApproval",
      });
      this.broadcastRuntimeThread(approval.threadId);
      this.scheduleThreadDetailBroadcast(approval.threadId);
      return;
    }

    const threadId = this.extractStringByKeys(request.params, ["threadId", "conversationId"]) ?? this.extractNestedThreadId(request.params);
    if (!threadId) {
      return;
    }

    this.threadBackendIds.set(threadId, backendId);

    this.runtime.recordEvent({
      threadId,
      turnId: this.extractStringByKeys(request.params, ["turnId"]),
      itemId: this.extractStringByKeys(request.params, ["itemId", "callId"]),
      method: request.method,
      title: this.titleForMethod(request.method),
      detail: this.bestDetail(request.params),
      phase: "waitingApproval",
    });
    this.broadcastRuntimeThread(threadId);
    this.scheduleThreadDetailBroadcast(threadId);
  }

  private buildPendingApproval(backendId: string, request: ServerRequestEvent): PendingApprovalRecord {
    const kind: ApprovalKind =
      request.method === "item/commandExecution/requestApproval"
        ? "command"
        : request.method === "item/fileChange/requestApproval"
          ? "fileChange"
          : "permissions";

    const threadId = this.extractStringByKeys(request.params, ["threadId", "conversationId"]);
    if (!threadId) {
      throw new Error("Approval request missing threadId");
    }

    const title =
      kind === "command"
        ? "Command approval needed"
        : kind === "fileChange"
          ? "File change approval needed"
          : "Permission decision needed";

    return {
      requestId: String(request.id),
      backendId,
      method: request.method,
      threadId,
      turnId: this.extractStringByKeys(request.params, ["turnId"]),
      itemId: this.extractStringByKeys(request.params, ["itemId", "callId"]),
      kind,
      title,
      detail: kind === "permissions" ? this.permissionApprovalDetail(request.params) : this.bestDetail(request.params),
      requestedAt: Date.now(),
      canRespond: true,
      supportsAcceptForSession: kind === "permissions",
    };
  }

  private normalizeConversationEvent(method: string, params?: JSONValue): {
    title: string;
    detail: string | null;
    phase: RuntimePhase;
    turnId: string | null;
    itemId: string | null;
  } {
    const turnId = this.extractStringByKeys(params, ["turnId"]);
    const itemId = this.extractStringByKeys(params, ["itemId", "callId"]);
    const detail = this.bestDetail(params);

    if (method.includes("turn/started")) {
      return { title: "Turn started", detail, phase: "running", turnId, itemId };
    }

    if (method.includes("turn/completed")) {
      return { title: "Turn completed", detail, phase: "completed", turnId, itemId };
    }

    if (method.includes("turn/diff/updated") || method.includes("turn/diffUpdated")) {
      const diff = this.extractStringByKeys(params, ["diff"]);
      return { title: "Diff updated", detail: diff ?? detail, phase: "running", turnId, itemId };
    }

    if (method.includes("thread/started")) {
      return { title: "Thread started", detail, phase: "idle", turnId, itemId };
    }

    if (method.includes("error")) {
      return { title: "Codex reported an error", detail, phase: "blocked", turnId, itemId };
    }

    if (method.includes("item/") && method.includes("started")) {
      return { title: "Step started", detail, phase: "running", turnId, itemId };
    }

    if (method.includes("item/") && method.includes("completed")) {
      return { title: "Step completed", detail, phase: "running", turnId, itemId };
    }

    return { title: this.titleForMethod(method), detail, phase: "unknown", turnId, itemId };
  }

  private titleForMethod(method: string): string {
    const lastSegment = method.split("/").filter(Boolean).pop() ?? method;
    return lastSegment
      .replace(/([a-z])([A-Z])/g, "$1 $2")
      .replace(/[-_]/g, " ")
      .replace(/\b\w/g, (char) => char.toUpperCase());
  }

  private bestDetail(value?: JSONValue): string | null {
    const direct = this.fullText(value, ["reason", "command", "message", "summary", "cwd", "grantRoot"]);

    if (!direct) {
      return null;
    }

    return direct.length > 240 ? `${direct.slice(0, 237)}...` : direct;
  }

  private fullText(value?: JSONValue, keys?: string[]): string | null {
    if (keys && keys.length > 0) {
      const keyed = this.extractStringByKeys(value, keys);
      if (keyed) {
        return keyed;
      }
    }

    return extractReadableText(value, keys ?? []);
  }

  private extractNestedThreadId(value?: JSONValue): string | null {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return null;
    }

    const maybeThread = value["thread"];
    if (maybeThread && typeof maybeThread === "object" && !Array.isArray(maybeThread)) {
      const nested = maybeThread["id"];
      if (typeof nested === "string") {
        return nested;
      }
    }

    for (const entry of Object.values(value)) {
      const nested = this.extractNestedThreadId(entry);
      if (nested) {
        return nested;
      }
    }

    return null;
  }

  private extractStringByKeys(value: JSONValue | undefined, keys: string[]): string | null {
    if (value == null) {
      return null;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        const found = this.extractStringByKeys(item, keys);
        if (found) {
          return found;
        }
      }
      return null;
    }

    if (typeof value !== "object") {
      return null;
    }

    for (const key of keys) {
      const candidate = value[key];
      if (typeof candidate === "string" && candidate.trim().length > 0) {
        return candidate;
      }
    }

    for (const nested of Object.values(value)) {
      const found = this.extractStringByKeys(nested, keys);
      if (found) {
        return found;
      }
    }

    return null;
  }

  private extractFirstString(value?: JSONValue): string | null {
    if (value == null) {
      return null;
    }

    if (typeof value === "string" && value.trim().length > 0) {
      return value;
    }

    if (Array.isArray(value)) {
      for (const item of value) {
        const found = this.extractFirstString(item);
        if (found) {
          return found;
        }
      }
      return null;
    }

    if (typeof value === "object") {
      for (const nested of Object.values(value)) {
        const found = this.extractFirstString(nested);
        if (found) {
          return found;
        }
      }
    }

    return null;
  }

  private normalizeThreadDetail(
    result: JSONValue | undefined,
    backend: BackendSummary,
    summary: ThreadSummary | null = null
  ): ThreadDetail | null {
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      return null;
    }

    const thread = result.thread;
    if (!thread || typeof thread !== "object" || Array.isArray(thread)) {
      return null;
    }

    const turns = Array.isArray(thread.turns)
      ? thread.turns
          .map((turn) => this.normalizeThreadTurn(turn))
          .filter((turn): turn is ThreadDetailTurn => turn !== null)
      : [];

    const trimmedTurns = this.trimThreadTurns(turns);

    const updatedAt = this.normalizeThreadUpdatedAt(
      typeof thread.updatedAt === "number" ? thread.updatedAt : summary?.updatedAt ?? 0
    );
    const status = this.preferredThreadStatus(
      this.codexThreadStatusValue(thread.status),
      summary?.status ?? null,
      updatedAt,
      {
        preferRecentIdle: trimmedTurns.length === 0,
      }
    );

    return {
      id: typeof thread.id === "string" ? thread.id : "",
      name: typeof thread.name === "string" ? thread.name : null,
      cwd: typeof thread.cwd === "string" ? thread.cwd : "",
      workspacePath: summary?.workspacePath ?? null,
      status,
      updatedAt,
      sourceKind: summary?.sourceKind ?? null,
      launchSource: summary?.launchSource ?? null,
      backendId: backend.id,
      backendLabel: backend.label,
      backendKind: backend.kind,
      command: backend.command,
      affordances: this.threadAffordancesForThread(backend, summary),
      turns: trimmedTurns,
    };
  }

  private codexThreadStatusValue(status: unknown): string | null {
    if (typeof status === "string" && status.length > 0) {
      return status === "active" ? "running" : status;
    }
    if (
      status &&
      typeof status === "object" &&
      !Array.isArray(status) &&
      "type" in status &&
      typeof status.type === "string" &&
      status.type.length > 0
    ) {
      return status.type === "active" ? "running" : status.type;
    }
    return null;
  }

  private withLiveRuntimeTail(detail: ThreadDetail, backendId: string): ThreadDetail {
    const tail = this.liveRuntimeOutputTailForThread(detail.id, backendId);
    if (!tail) {
      return detail;
    }

    const turnID = `live-tail-${detail.id}`;
    const ageMS = Math.max(0, Date.now() - tail.updatedAt);
    const isActiveTail = ageMS <= 15_000;

    const liveTurn: ThreadDetailTurn = {
      id: turnID,
      status: isActiveTail ? "running" : "completed",
      error: null,
      items: [{
        id: `live-tail-item-${detail.id}`,
        turnId: turnID,
        type: "commandExecution",
        title: "Live terminal",
        detail: "Live output from the attached helm session.",
        status: isActiveTail ? "running" : "completed",
        rawText: tail.text,
        metadataSummary: "Live attached terminal output",
        command: null,
        cwd: detail.cwd,
        exitCode: null,
      }],
    };

    return {
      ...detail,
      updatedAt: Math.max(detail.updatedAt, tail.updatedAt),
      turns: this.trimThreadTurns([
        ...detail.turns.filter((turn) => turn.id !== turnID),
        liveTurn,
      ]),
    };
  }

  private liveRuntimeOutputTailForThread(
    threadId: string,
    backendId: string
  ): RuntimeOutputTail | null {
    const runtimeId = this.runtimeIdForBackend(backendId);
    if (!runtimeId) {
      return null;
    }

    let launch = findMatchingLaunchByThreadID(runtimeId, threadId);
    if (!launch && threadId.startsWith(`${runtimeId}:`)) {
      const pid = Number(threadId.slice(runtimeId.length + 1));
      launch = findMatchingLaunchByPID(runtimeId, Number.isFinite(pid) ? pid : undefined);
    }
    if (!launch) {
      return null;
    }

    return readRuntimeOutputTail(launch);
  }

  private threadSummaryFromRuntimeLaunch(
    launch: RuntimeLaunchRecord,
    threadId: string,
    backendId: string,
    tail: RuntimeOutputTail
  ): ThreadSummary {
    const backend = this.backendForId(backendId).summary;
    const cwdName = path.basename(launch.cwd) || launch.cwd || backend.label;
    return {
      id: threadId,
      name: `${backend.label} - ${cwdName}`,
      preview: this.previewText(tail.text) || `${backend.label} is running as a helm-managed terminal session.`,
      cwd: launch.cwd,
      workspacePath: null,
      status: "running",
      updatedAt: this.normalizeThreadUpdatedAt(tail.updatedAt),
      sourceKind: "managed-terminal",
      launchSource: HELM_RUNTIME_LAUNCH_SOURCE,
      backendId: backend.id,
      backendLabel: backend.label,
      backendKind: backend.kind,
      controller: this.controllers.get(threadId),
    };
  }

  private runtimeIdForBackend(backendId: string): string | null {
    switch (backendId) {
    case "codex":
      return "codex";
    case "claude-code":
      return "claude";
    default:
      return this.backends.has(backendId) ? backendId : null;
    }
  }

  private backendIdForRuntime(runtime: string): string | null {
    switch (runtime) {
    case "codex":
      return "codex";
    case "claude":
      return "claude-code";
    default:
      return this.backends.has(runtime) ? runtime : null;
    }
  }

  private normalizeThreadUpdatedAt(value: number): number {
    if (!Number.isFinite(value) || value <= 0) {
      return Date.now();
    }

    return value > 1_000_000_000_000 ? value : value * 1000;
  }

  private preferredThreadStatus(
    primary: string | null,
    fallback: string | null,
    updatedAt: number,
    options: {
      preferRecentIdle?: boolean;
    } = {}
  ): string {
    if (primary && primary !== "unknown" && primary !== "notLoaded") {
      return primary;
    }

    if (fallback && fallback !== "unknown" && fallback !== "notLoaded") {
      return fallback;
    }

    const ageMS = Math.max(0, Date.now() - this.normalizeThreadUpdatedAt(updatedAt));
    if (options.preferRecentIdle) {
      if (ageMS < 7 * 24 * 60 * 60 * 1000) {
        return "idle";
      }
      return "unknown";
    }
    if (ageMS < 15 * 60 * 1000) {
      return "running";
    }
    if (ageMS < 7 * 24 * 60 * 60 * 1000) {
      return "idle";
    }
    return "unknown";
  }

  private normalizeThreadTurn(value: JSONValue): ThreadDetailTurn | null {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return null;
    }

    const turnId = typeof value.id === "string" ? value.id : "";

    const items = Array.isArray(value.items)
      ? value.items
          .map((item) => this.normalizeThreadItem(item))
          .filter((item): item is ThreadDetailItem => item !== null)
          .map((item) => ({
            ...item,
            turnId,
          }))
      : [];

    return {
      id: turnId,
      status: typeof value.status === "string" ? value.status : "unknown",
      error: this.extractStringByKeys(value.error, ["message"]) ?? this.extractFirstString(value.error),
      items,
    };
  }

  private normalizeThreadItem(value: JSONValue): ThreadDetailItem | null {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return null;
    }

    const type = typeof value.type === "string" ? value.type : "unknown";
    const id = typeof value.id === "string" ? value.id : `${type}-${Math.random().toString(36).slice(2, 8)}`;

    switch (type) {
      case "userMessage":
        return {
          id,
          turnId: null,
          type,
          title: "User message",
          detail: this.extractStringByKeys(value.content, ["text"]) ?? this.bestDetail(value.content),
          status: null,
          rawText: this.extractStringByKeys(value.content, ["text"]) ?? this.bestDetail(value.content),
          metadataSummary: null,
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "agentMessage":
        return {
          id,
          turnId: null,
          type,
          title: "Codex response",
          detail: this.bestDetail(value.text),
          status: typeof value.phase === "string" ? value.phase : null,
          rawText: this.fullText(value.text),
          metadataSummary: null,
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "plan":
        return {
          id,
          turnId: null,
          type,
          title: "Plan",
          detail: typeof value.text === "string" ? value.text : null,
          status: null,
          rawText: typeof value.text === "string" ? value.text : null,
          metadataSummary: null,
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "reasoning":
        return {
          id,
          turnId: null,
          type,
          title: "Reasoning",
          detail: this.bestDetail(value.summary) ?? this.bestDetail(value.content),
          status: null,
          rawText: this.fullText(value.content) ?? this.fullText(value.summary),
          metadataSummary: null,
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "commandExecution": {
        const output =
          this.fullText(value.aggregatedOutput) ??
          this.fullText(value.stdout) ??
          this.fullText(value.stderr);
        const cwd = typeof value.cwd === "string" ? value.cwd : null;
        const exitCode = typeof value.exitCode === "number" ? value.exitCode : null;
        return {
          id,
          turnId: null,
          type,
          title: typeof value.command === "string" ? value.command : "Command execution",
          detail:
            this.commandExecutionDetail(value) ??
            output ??
            this.extractStringByKeys(value, ["cwd"]),
          status: typeof value.status === "string" ? value.status : null,
          rawText: output,
          metadataSummary: this.commandExecutionMetadataSummary(value),
          command: typeof value.command === "string" ? value.command : null,
          cwd,
          exitCode,
        };
      }
      case "fileChange":
        return {
          id,
          turnId: null,
          type,
          title: "File changes",
          detail: this.fileChangeDetail(value.changes),
          status: typeof value.status === "string" ? value.status : null,
          rawText: this.fileChangeRawText(value.changes),
          metadataSummary: this.fileChangeMetadataSummary(value.changes),
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "mcpToolCall":
        return {
          id,
          turnId: null,
          type,
          title:
            typeof value.server === "string" && typeof value.tool === "string"
              ? `${value.server} / ${value.tool}`
              : "MCP tool call",
          detail: this.bestDetail(value.result) ?? this.bestDetail(value.error),
          status: typeof value.status === "string" ? value.status : null,
          rawText: this.bestDetail(value.result) ?? this.bestDetail(value.error),
          metadataSummary: this.toolMetadataSummary(value),
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "dynamicToolCall":
        return {
          id,
          turnId: null,
          type,
          title: typeof value.tool === "string" ? value.tool : "Dynamic tool call",
          detail: this.bestDetail(value.contentItems),
          status: typeof value.status === "string" ? value.status : null,
          rawText: this.bestDetail(value.contentItems),
          metadataSummary: this.toolMetadataSummary(value),
          command: null,
          cwd: null,
          exitCode: null,
        };
      case "webSearch":
        return {
          id,
          turnId: null,
          type,
          title: "Web search",
          detail: typeof value.query === "string" ? value.query : null,
          status: null,
          rawText: this.bestDetail(value.query),
          metadataSummary: this.webSearchMetadataSummary(value),
          command: null,
          cwd: null,
          exitCode: null,
        };
      default:
        return {
          id,
          turnId: null,
          type,
          title: this.titleForMethod(type),
          detail: this.bestDetail(value),
          status: this.extractStringByKeys(value, ["status", "phase"]),
          rawText: this.bestDetail(value),
          metadataSummary: this.genericMetadataSummary(value),
          command: null,
          cwd: null,
          exitCode: null,
        };
    }
  }

  private trimThreadTurns(turns: ThreadDetailTurn[]): ThreadDetailTurn[] {
    const budgetedTurns = this.compactOversizedThreadTurns(turns);
    const liveTailTurns = budgetedTurns.filter((turn) => turn.id.startsWith("live-tail-"));
    if (liveTailTurns.length > 0) {
      const liveTailIds = new Set(liveTailTurns.map((turn) => turn.id));
      const remainingTurns = budgetedTurns.filter((turn) => !liveTailIds.has(turn.id));
      const liveTailItemCount = liveTailTurns.reduce((sum, turn) => sum + turn.items.length, 0);
      const selectedRemainingTurns = this.selectRecentThreadTurns(
        remainingTurns,
        Math.max(1, BridgeServer.THREAD_DETAIL_MAX_TURNS - liveTailTurns.length),
        Math.max(1, BridgeServer.THREAD_DETAIL_MAX_ITEMS - liveTailItemCount)
      );

      return this.compactThreadDetailTurns([...selectedRemainingTurns, ...liveTailTurns]);
    }

    if (budgetedTurns.length <= BridgeServer.THREAD_DETAIL_MAX_TURNS) {
      const itemCount = budgetedTurns.reduce((sum, turn) => sum + turn.items.length, 0);
      if (itemCount <= BridgeServer.THREAD_DETAIL_MAX_ITEMS) {
        return this.compactThreadDetailTurns(budgetedTurns);
      }
    }

    return this.compactThreadDetailTurns(this.selectRecentThreadTurns(
      budgetedTurns,
      BridgeServer.THREAD_DETAIL_MAX_TURNS,
      BridgeServer.THREAD_DETAIL_MAX_ITEMS
    ));
  }

  private compactOversizedThreadTurns(turns: ThreadDetailTurn[]): ThreadDetailTurn[] {
    return turns.map((turn) => this.compactOversizedThreadTurn(turn));
  }

  private compactOversizedThreadTurn(turn: ThreadDetailTurn): ThreadDetailTurn {
    const maxItems = BridgeServer.THREAD_DETAIL_MAX_ITEMS_PER_TURN;
    if (turn.items.length <= maxItems) {
      return turn;
    }

    const selectedIds = new Set<string>();
    const selectedIndexes = new Set<number>();
    const maxRealItems = maxItems;

    const addItemAtIndex = (index: number): void => {
      if (selectedIndexes.size >= maxRealItems) {
        return;
      }

      const item = turn.items[index];
      if (!item || selectedIds.has(item.id)) {
        return;
      }

      selectedIds.add(item.id);
      selectedIndexes.add(index);
    };

    const firstUserMessageIndex = turn.items.findIndex((item) => item.type === "userMessage");
    if (firstUserMessageIndex >= 0) {
      addItemAtIndex(firstUserMessageIndex);
    }

    for (let index = turn.items.length - 1; index >= 0; index -= 1) {
      addItemAtIndex(index);
    }

    const keptIndexes = Array.from(selectedIndexes).sort((lhs, rhs) => lhs - rhs);
    const keptItems = keptIndexes
      .map((index) => turn.items[index])
      .filter((item): item is ThreadDetailItem => item !== undefined);
    const omittedCount = turn.items.length - keptItems.length;
    if (omittedCount <= 0) {
      return turn;
    }

    return {
      ...turn,
      items: keptItems,
    };
  }

  private selectRecentThreadTurns(
    turns: ThreadDetailTurn[],
    maxTurns: number,
    maxItems: number
  ): ThreadDetailTurn[] {
    const selected: ThreadDetailTurn[] = [];
    let itemCount = 0;

    for (const turn of [...turns].reverse()) {
      const nextItemCount = itemCount + turn.items.length;
      if (
        selected.length >= maxTurns
        || (selected.length > 0 && nextItemCount > maxItems)
      ) {
        break;
      }

      selected.push(turn);
      itemCount = nextItemCount;
    }

    return selected.reverse();
  }

  private compactThreadDetailTurns(turns: ThreadDetailTurn[]): ThreadDetailTurn[] {
    return turns.map((turn) => ({
      ...turn,
      items: turn.items.map((item) => this.compactThreadDetailItem(item)),
    }));
  }

  private compactThreadDetailItem(item: ThreadDetailItem): ThreadDetailItem {
    const textLimit = this.threadDetailTextLimit(item);
    const preserveTail = this.threadDetailTextPreservesTail(item);
    return {
      ...item,
      detail: this.compactThreadDetailText(item.detail, textLimit, preserveTail),
      rawText: this.compactThreadDetailText(item.rawText, textLimit, preserveTail),
    };
  }

  private compactThreadDetailForWebSocket(detail: ThreadDetail): ThreadDetail {
    const selectedTurns = this.selectRecentThreadTurns(
      this.compactOversizedThreadTurns(detail.turns),
      BridgeServer.THREAD_DETAIL_WS_MAX_TURNS,
      BridgeServer.THREAD_DETAIL_WS_MAX_ITEMS
    );

    return {
      ...detail,
      turns: selectedTurns.map((turn) => ({
        ...turn,
        items: turn.items.map((item) => this.compactThreadDetailItemForWebSocket(item)),
      })),
    };
  }

  private compactThreadDetailItemForWebSocket(item: ThreadDetailItem): ThreadDetailItem {
    const textLimit = this.threadDetailWebSocketTextLimit(item);
    const preserveTail = this.threadDetailTextPreservesTail(item);
    return {
      ...item,
      detail: this.compactThreadDetailText(item.detail, textLimit, preserveTail),
      rawText: this.compactThreadDetailText(item.rawText, textLimit, preserveTail),
    };
  }

  private threadDetailTextLimit(item: ThreadDetailItem): number {
    switch (item.type) {
      case "agentMessage":
        return BridgeServer.THREAD_DETAIL_MAX_MESSAGE_TEXT_CHARS;
      case "commandExecution":
        return BridgeServer.THREAD_DETAIL_MAX_TERMINAL_TEXT_CHARS;
      default:
        return BridgeServer.THREAD_DETAIL_MAX_TEXT_CHARS;
    }
  }

  private threadDetailWebSocketTextLimit(item: ThreadDetailItem): number {
    switch (item.type) {
      case "agentMessage":
        return BridgeServer.THREAD_DETAIL_WS_MAX_MESSAGE_TEXT_CHARS;
      case "commandExecution":
        return BridgeServer.THREAD_DETAIL_WS_MAX_TERMINAL_TEXT_CHARS;
      case "reasoning":
        return BridgeServer.THREAD_DETAIL_WS_MAX_REASONING_TEXT_CHARS;
      default:
        return BridgeServer.THREAD_DETAIL_WS_MAX_TEXT_CHARS;
    }
  }

  private threadDetailTextPreservesTail(item: ThreadDetailItem): boolean {
    switch (item.type) {
      case "agentMessage":
      case "commandExecution":
      case "reasoning":
        return true;
      default:
        return false;
    }
  }

  private compactThreadDetailText(
    value: string | null,
    limit: number,
    preserveTail: boolean
  ): string | null {
    if (!value || value.length <= limit) {
      return value;
    }

    if (preserveTail) {
      return value.slice(-limit);
    }
    return value.slice(0, limit);
  }

  private threadPreviewFromDetail(detail: ThreadDetail): string {
    const snippets: string[] = [];

    for (const turn of [...detail.turns].reverse()) {
      for (const item of [...turn.items].reverse()) {
        if (item.type !== "userMessage" && item.type !== "agentMessage") {
          continue;
        }

        const text = this.previewText(item.rawText ?? item.detail);
        if (!text) {
          continue;
        }

        if (snippets[0] === text) {
          continue;
        }

        snippets.unshift(text);
        if (snippets.length >= 2) {
          return snippets.join("\n");
        }
      }
    }

    return snippets.join("\n");
  }

  private resolvedThreadPreview(
    primaryPreview: string,
    status: string,
    fallbackPreview: string | null = null,
    fallbackName: string | null = null
  ): string {
    const trimmedPrimary = this.previewText(primaryPreview);
    if (trimmedPrimary) {
      return trimmedPrimary;
    }

    const trimmedFallback = this.previewText(fallbackPreview);
    const trimmedName = this.previewText(fallbackName);
    const normalizedStatus = status.trim().toLowerCase();
    const titleEcho = (candidate: string): boolean =>
      candidate.length > 0
      && trimmedName.length > 0
      && candidate === trimmedName;
    const titleEchoShouldYieldPlaceholder = (candidate: string): boolean =>
      (normalizedStatus === "running" || normalizedStatus === "idle")
      && titleEcho(candidate);
    if (trimmedFallback && !titleEchoShouldYieldPlaceholder(trimmedFallback)) {
      return trimmedFallback;
    }

    if (normalizedStatus === "idle" && (titleEcho(trimmedPrimary) || titleEcho(trimmedFallback))) {
      return "No activity yet.";
    }

    return normalizedStatus === "running" ? "Waiting for output..." : "";
  }

  private mergedThreadPreview(
    primaryPreview: string,
    status: string,
    fallbackPreview: string | null = null,
    fallbackName: string | null = null
  ): string {
    const trimmedFallback = this.previewText(fallbackPreview);
    if (this.shouldPreserveStableThreadPreview(status, trimmedFallback, fallbackName)) {
      return trimmedFallback;
    }

    return this.resolvedThreadPreview(primaryPreview, status, fallbackPreview, fallbackName);
  }

  private shouldPreserveStableThreadPreview(
    status: string,
    fallbackPreview: string,
    fallbackName: string | null = null
  ): boolean {
    if (!fallbackPreview || this.isGenericThreadPreview(fallbackPreview)) {
      return false;
    }

    const trimmedName = this.previewText(fallbackName);
    if (trimmedName && trimmedName === fallbackPreview) {
      return false;
    }

    switch (status.trim().toLowerCase()) {
    case "running":
    case "blocked":
    case "waitingapproval":
      return false;
    default:
      return true;
    }
  }

  private isGenericThreadPreview(preview: string): boolean {
    return preview === "Codex CLI session"
      || preview === "Waiting for output..."
      || preview.endsWith("is running as a helm-managed terminal session.");
  }

  private previewText(value: string | null | undefined): string {
    if (!value) {
      return "";
    }

    const normalized = value
      .replace(/\r\n/g, "\n")
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .slice(0, 2)
      .join("\n");

    if (!normalized) {
      return "";
    }

    return normalized.length <= 280
      ? normalized
      : `${normalized.slice(0, 279).trimEnd()}…`;
  }

  private withControllerMetadata(threads: ThreadSummary[]): ThreadSummary[] {
    return threads.map((thread) => {
      this.threadBackendIds.set(thread.id, thread.backendId);
      return {
        ...thread,
        controller: this.controllers.get(thread.id),
      };
    });
  }

  private backendSummaries(): BackendSummary[] {
    return Array.from(this.backends.values())
      .map((backend) => backend.summary)
      .sort((lhs, rhs) => Number(rhs.isDefault) - Number(lhs.isDefault) || lhs.label.localeCompare(rhs.label));
  }

  private futureBackends(): AgentBackend[] {
    return [
      new ManagedTerminalBackend({
        id: "grok",
        label: "Grok",
        kind: "grok",
        description: "Grok CLI sessions controlled by helm's managed terminal relay.",
        runtime: "grok",
        commandCandidates: ["grok", "grok-cli"],
        availabilityDetail:
          "Grok CLI is available. helm can launch it as a managed terminal session and inject turns from mobile.",
        unavailableDetail:
          "Grok CLI was not found. Install the grokcli.io CLI, then re-run helm setup or make sure grok/grok-cli is on PATH.",
        installHint: "Install from https://grokcli.io/ and ensure grok or grok-cli is on PATH.",
        wrapperName: "helm-grok",
        command: {
          handoff: "isolated",
          notes:
            "helm launches the grokcli.io terminal app under its runtime relay. Mobile sends text into that live terminal session; Grok owns provider authentication and transcript behavior.",
        },
      }),
      new ManagedTerminalBackend({
        id: "local-gemma-4",
        label: "Gemma 4",
        kind: "local",
        description: "Local Gemma model sessions run through Ollama under helm's managed terminal relay.",
        runtime: "local-gemma-4",
        commandCandidates: ["ollama"],
        defaultModel: process.env.HELM_GEMMA_MODEL?.trim() || "gemma4",
        modelOptions: [
          process.env.HELM_GEMMA_MODEL?.trim() || "gemma4",
          "gemma4",
          "gemma3:27b",
          "gemma3:12b",
        ],
        buildArgs: (_input, model) => ["run", model || process.env.HELM_GEMMA_MODEL?.trim() || "gemma4"],
        availabilityDetail:
          "Ollama is available. helm can launch a local Gemma profile as a managed terminal session.",
        unavailableDetail:
          "Ollama was not found. Install Ollama and pull the Gemma model you want to use, then start a Gemma session from helm.",
        installHint: "Install Ollama and set HELM_GEMMA_MODEL if your local Gemma tag is not gemma4.",
        wrapperName: "helm-local-gemma",
        command: {
          handoff: "isolated",
          notes:
            "helm launches `ollama run` for the selected Gemma tag. Local model availability depends on the Ollama model names installed on this Mac.",
        },
      }),
      new ManagedTerminalBackend({
        id: "local-qwen-3.5",
        label: "Qwen3.5",
        kind: "local",
        description: "Local Qwen model sessions run through Ollama under helm's managed terminal relay.",
        runtime: "local-qwen-3.5",
        commandCandidates: ["ollama"],
        defaultModel: process.env.HELM_QWEN_MODEL?.trim() || "qwen3.5",
        modelOptions: [
          process.env.HELM_QWEN_MODEL?.trim() || "qwen3.5",
          "qwen3.5",
          "qwen3:32b",
          "qwen3:14b",
        ],
        buildArgs: (_input, model) => ["run", model || process.env.HELM_QWEN_MODEL?.trim() || "qwen3.5"],
        availabilityDetail:
          "Ollama is available. helm can launch a local Qwen profile as a managed terminal session.",
        unavailableDetail:
          "Ollama was not found. Install Ollama and pull the Qwen model you want to use, then start a Qwen session from helm.",
        installHint: "Install Ollama and set HELM_QWEN_MODEL if your local Qwen tag is not qwen3.5.",
        wrapperName: "helm-local-qwen",
        command: {
          handoff: "isolated",
          notes:
            "helm launches `ollama run` for the selected Qwen tag. Local model availability depends on the Ollama model names installed on this Mac.",
        },
      }),
      new UnavailableBackend({
        id: "opencode",
        label: "OpenCode",
        kind: "opencode",
        description: "Future helm support for OpenCode-backed agent sessions.",
        isDefault: false,
        available: false,
        availabilityDetail: "Planned. OpenCode is modeled as a future backend but is not connected yet.",
        capabilities: {
          threadListing: false,
          threadCreation: false,
          turnExecution: false,
          turnInterrupt: false,
          approvals: false,
          planMode: false,
          voiceCommand: false,
          realtimeVoice: false,
          hooksAndSkillsParity: false,
          sharedThreadHandoff: false,
        },
        command: {
          routing: "providerChat",
          approvals: "providerManaged",
          handoff: "sessionResume",
          voiceInput: "unsupported",
          voiceOutput: "none",
          supportsCommandFollowups: false,
          notes:
            "Planned OpenCode backend. helm will need a provider-specific mapping for Command, approvals, and voice behavior.",
        },
      }),
      new ClaudeCodeBackend(),
      new UnavailableBackend({
        id: "gemini",
        label: "Gemini",
        kind: "gemini",
        description: "Future helm support for Gemini-backed agent sessions.",
        isDefault: false,
        available: false,
        availabilityDetail: "Planned. Gemini support is not connected yet.",
        capabilities: {
          threadListing: false,
          threadCreation: false,
          turnExecution: false,
          turnInterrupt: false,
          approvals: false,
          planMode: false,
          voiceCommand: false,
          realtimeVoice: false,
          hooksAndSkillsParity: false,
          sharedThreadHandoff: false,
        },
        command: {
          routing: "providerChat",
          approvals: "providerManaged",
          handoff: "sessionResume",
          voiceInput: "unsupported",
          voiceOutput: "none",
          supportsCommandFollowups: false,
          notes:
            "Planned Gemini backend. helm will need backend-specific mappings for Command and voice paths.",
        },
      }),
    ];
  }

  private async listThreadsAcrossBackends(): Promise<ThreadSummary[]> {
    const results = await Promise.all(
      Array.from(this.backends.values()).map(async (backend) => await backend.listThreads())
    );

    return this.stabilizeDiscoveredThreads(await this.withWorkspacePaths(results.flat()));
  }

  private async withWorkspacePaths(threads: ThreadSummary[]): Promise<ThreadSummary[]> {
    return await Promise.all(
      threads.map(async (thread) => {
        const workspacePath = await resolveWorkspacePath(thread.cwd);
        return {
          ...thread,
          workspacePath: workspacePath || null,
        };
      })
    );
  }

  private stabilizeDiscoveredThreads(discoveredThreads: ThreadSummary[]): ThreadSummary[] {
    const now = Date.now();
    const seenThreadIDs = new Set<string>();
    const mergedThreads = new Map<string, ThreadSummary>();
    const replacedThreadIDs = new Set(
      listCodexThreadReplacements("codex").map((record) => record.oldThreadId)
    );

    for (const thread of discoveredThreads) {
      if (replacedThreadIDs.has(thread.id)) {
        this.retireReplacedThreadState(thread.id);
        continue;
      }
      seenThreadIDs.add(thread.id);
      this.discoveredThreadCache.set(thread.id, {
        thread,
        lastSeenAt: now,
      });
      mergedThreads.set(thread.id, thread);
    }

    for (const [threadId, record] of this.discoveredThreadCache.entries()) {
      if (replacedThreadIDs.has(threadId)) {
        this.retireReplacedThreadState(threadId);
        continue;
      }
      if (seenThreadIDs.has(threadId)) {
        continue;
      }

      const graceMS = this.discoveryGracePeriod(record.thread);
      if (now - record.lastSeenAt <= graceMS) {
        mergedThreads.set(threadId, record.thread);
        continue;
      }

      this.discoveredThreadCache.delete(threadId);
      this.threadBackendIds.delete(threadId);
    }

    return Array.from(mergedThreads.values()).sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt);
  }

  private discoveryGracePeriod(thread: ThreadSummary): number {
    if (thread.status === "running" || thread.controller != null) {
      return BridgeServer.THREAD_ACTIVE_DISCOVERY_GRACE_MS;
    }

    return BridgeServer.THREAD_RECENT_DISCOVERY_GRACE_MS;
  }

  private canonicalThreadId(threadId: string): string {
    return canonicalCodexThreadId("codex", threadId);
  }

  private async resolveCodexThreadTarget(threadTarget: string): Promise<string> {
    const trimmedTarget = threadTarget.trim();
    if (!trimmedTarget) {
      throw new HttpError(400, "Missing thread target");
    }

    if (CODEX_THREAD_ID_RE.test(trimmedTarget)) {
      return trimmedTarget;
    }

    const resolved = await resolveCodexThreadByName(trimmedTarget);
    if (resolved.status === "resolved") {
      return resolved.thread.id;
    }

    if (resolved.status === "ambiguous") {
      const matches = resolved.matches
        .slice(0, 5)
        .map((thread) => {
          const displayName = thread.name?.trim() || "Untitled Session";
          return `${displayName} (${thread.id})`;
        })
        .join(", ");
      throw new HttpError(
        409,
        `Ambiguous Codex thread name '${trimmedTarget}'. Rename one of the duplicates or resume by id. Matches: ${matches}`
      );
    }

    throw new HttpError(404, `Codex thread target not found: ${trimmedTarget}`);
  }

  private async openCanonicalThreadTarget(
    threadTarget: string,
    options: {
      launchManagedShell: boolean;
      preferVisibleLaunch: boolean;
    }
  ): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
  }> {
    const resolvedThreadId = await this.resolveCodexThreadTarget(threadTarget);
    return await this.openCanonicalThread(resolvedThreadId, options);
  }

  private async openCanonicalThread(
    threadId: string,
    options: {
      launchManagedShell: boolean;
      preferVisibleLaunch: boolean;
    }
  ): Promise<{
    threadId: string;
    previousThreadId: string | null;
    replaced: boolean;
    launched: boolean;
  }> {
    const backend = this.backendForThread(threadId);

    if (backend instanceof CodexBackend) {
      const ensured = await backend.ensureManagedShellThread(threadId, {
        launchManagedShell: options.launchManagedShell,
        preferVisibleLaunch: options.preferVisibleLaunch,
      });

      this.threadBackendIds.set(ensured.threadId, backend.summary.id);
      if (ensured.previousThreadId) {
        this.retireReplacedThreadState(ensured.previousThreadId);
        this.threadBackendIds.delete(ensured.previousThreadId);
      }

      return {
        threadId: ensured.threadId,
        previousThreadId: ensured.previousThreadId,
        replaced: ensured.replaced || ensured.threadId !== threadId,
        launched: ensured.launched,
      };
    }

    const canonicalThreadId = this.canonicalThreadId(threadId);

    if (backend instanceof ClaudeCodeBackend) {
      const ensured = await backend.ensureManagedSession(canonicalThreadId);
      this.threadBackendIds.set(ensured.threadId, backend.summary.id);
      return {
        threadId: ensured.threadId,
        previousThreadId: canonicalThreadId === threadId ? null : threadId,
        replaced: canonicalThreadId !== threadId,
        launched: ensured.launched,
      };
    }

    return {
      threadId: canonicalThreadId,
      previousThreadId: canonicalThreadId === threadId ? null : threadId,
      replaced: canonicalThreadId !== threadId,
      launched: false,
    };
  }

  private retireReplacedThreadState(threadId: string): void {
    this.discoveredThreadCache.delete(threadId);
    this.threadBackendIds.delete(threadId);
    this.mirroredThreadDetailCache.delete(threadId);
    this.mirroredThreadDetailObjectCache.delete(threadId);
    this.threadDetailPollRefreshAt.delete(threadId);
    this.runtimeTailDetailRefreshAttemptAt.delete(threadId);
    this.runtime.remove(threadId);
    this.controllers.remove(threadId);
    this.invalidateThreadListCache();
  }

  private refreshRuntimePresenceFromLaunches(): void {
    this.reconcileCodexImplicitResumeLaunches();
    this.reconcileCodexLaunchThreadReplacements();

    const presenceByThreadID = new Map<string, {
      threadId: string;
      lastUpdatedAt: number;
      title: string;
      detail: string | null;
    }>();

    for (const launch of listRuntimeLaunches()) {
      if (!isRuntimeRelayAvailable(launch) || !launch.threadId) {
        continue;
      }

      const threadId = canonicalRuntimeThreadId(launch.runtime, launch.threadId);
      if (!threadId) {
        continue;
      }
      const existing = presenceByThreadID.get(threadId);
      const next = {
        threadId,
        lastUpdatedAt: launch.launchedAt,
        title: "Attached",
        detail: `helm ${launch.runtime} session is attached`,
      };

      if (!existing || existing.lastUpdatedAt < next.lastUpdatedAt) {
        presenceByThreadID.set(threadId, next);
      }
    }

    this.runtime.syncManagedPresence(Array.from(presenceByThreadID.values()));
  }

  private reconcileCodexImplicitResumeLaunches(): void {
    const launches = listRuntimeLaunches("codex");
    const unstampedLaunches = launches.filter((launch) => isRuntimeRelayAvailable(launch) && !launch.threadId);
    if (unstampedLaunches.length === 0) {
      return;
    }

    const rows = this.readRecentCodexThreadRows();
    if (rows.length === 0) {
      return;
    }

    const occupiedThreadIDs = new Set(
      launches
        .map((launch) => canonicalRuntimeThreadId("codex", launch.threadId))
        .filter((threadId): threadId is string => typeof threadId === "string" && threadId.length > 0)
    );

    for (const launch of unstampedLaunches) {
      const candidates = rows
        .filter((row): row is CodexThreadRegistryRow & { id: string; cwd: string } =>
          typeof row.id === "string"
          && row.id.length > 0
          && typeof row.cwd === "string"
          && row.cwd === launch.cwd
        )
        .filter((row) => this.codexThreadSource(row) === "cli")
        .filter((row) => !occupiedThreadIDs.has(row.id))
        .sort((lhs, rhs) => this.normalizeCodexRegistryUpdatedAt(rhs.updated_at) - this.normalizeCodexRegistryUpdatedAt(lhs.updated_at));

      const candidate = candidates[0];
      if (!candidate) {
        continue;
      }

      const candidateUpdatedAt = this.normalizeCodexRegistryUpdatedAt(candidate.updated_at);
      const nextCandidateUpdatedAt = this.normalizeCodexRegistryUpdatedAt(candidates[1]?.updated_at);
      if (
        nextCandidateUpdatedAt > 0
        && candidateUpdatedAt - nextCandidateUpdatedAt < BridgeServer.CODEX_IMPLICIT_RESUME_CANDIDATE_GAP_MS
      ) {
        continue;
      }

      const updatedLaunch = updateRuntimeLaunchThreadId("codex", launch.pid, candidate.id);
      if (!updatedLaunch) {
        continue;
      }

      occupiedThreadIDs.add(candidate.id);
      console.warn(
        `[bridge] Backfilled implicit Codex resume launch ${launch.pid} with thread ${candidate.id}.`
      );
    }
  }

  private reconcileCodexLaunchThreadReplacements(): void {
    const launches = listRuntimeLaunches("codex").filter((launch) => launch.threadId);
    if (launches.length === 0) {
      return;
    }

    const rows = this.readRecentCodexThreadRows();
    if (rows.length === 0) {
      return;
    }

    const rowsById = new Map(
      rows
        .filter((row): row is CodexThreadRegistryRow & { id: string } => typeof row.id === "string" && row.id.length > 0)
        .map((row) => [row.id, row])
    );

    for (const record of listCodexThreadReplacements("codex")) {
      const oldRow = rowsById.get(record.oldThreadId);
      const newRow = rowsById.get(record.newThreadId);
      if (
        typeof oldRow?.cwd === "string"
        && typeof newRow?.cwd === "string"
        && oldRow.cwd !== newRow.cwd
      ) {
        deleteCodexThreadReplacement("codex", record.oldThreadId);
        console.warn(
          `[bridge] Removed stale cross-cwd Codex replacement ${record.oldThreadId} -> ${record.newThreadId}.`
        );
      }
    }

    const occupiedThreadIDs = new Set(
      launches
        .map((launch) => canonicalRuntimeThreadId("codex", launch.threadId))
        .filter((threadId): threadId is string => typeof threadId === "string" && threadId.length > 0)
    );

    for (const launch of launches) {
      const oldThreadId = canonicalRuntimeThreadId("codex", launch.threadId);
      if (!oldThreadId) {
        continue;
      }

      const exact = rowsById.get(oldThreadId);
      if (!exact) {
        continue;
      }

      if (this.codexThreadSource(exact) === "cli") {
        continue;
      }

      const exactName = this.codexComputedThreadName(exact);
      if (!exactName) {
        continue;
      }

      const exactUpdatedAt = this.normalizeCodexRegistryUpdatedAt(exact.updated_at);
      const candidates = rows
        .filter((row) => row.id && row.id !== oldThreadId)
        .filter((row) => this.codexThreadSource(row) === "cli")
        .filter((row) => typeof row.cwd === "string" && row.cwd === exact.cwd)
        .filter((row) => this.codexComputedThreadName(row) === exactName)
        .filter((row) => this.normalizeCodexRegistryUpdatedAt(row.updated_at) - exactUpdatedAt >= BridgeServer.CODEX_LAUNCH_THREAD_DRIFT_MIN_MS)
        .filter((row) => this.normalizeCodexRegistryUpdatedAt(row.updated_at) >= launch.launchedAt)
        .filter((row) => !occupiedThreadIDs.has(row.id!))
        .sort((lhs, rhs) => this.normalizeCodexRegistryUpdatedAt(rhs.updated_at) - this.normalizeCodexRegistryUpdatedAt(lhs.updated_at));

      if (candidates.length !== 1) {
        continue;
      }

      const nextThreadId = candidates[0]!.id!;
      recordCodexThreadReplacement("codex", oldThreadId, nextThreadId);
      occupiedThreadIDs.delete(oldThreadId);
      occupiedThreadIDs.add(nextThreadId);
      console.warn(
        `[bridge] Canonicalized live Codex launch ${oldThreadId} -> ${nextThreadId} for "${exactName}".`
      );
    }
  }

  private readRecentCodexThreadRows(
    limit = 200,
    options: { archived?: boolean } = {}
  ): CodexThreadRegistryRow[] {
    try {
      const archivedValue = options.archived ? 1 : 0;
      const raw = execFileSync(
        "sqlite3",
        [
          "-json",
          path.join(homedir(), ".codex", "state_5.sqlite"),
          `
            select
              id,
              updated_at,
              cwd,
              source,
              nullif(title, '') as title,
              nullif(first_user_message, '') as first_user_message
            from threads
            where archived = ${archivedValue}
              and source in ('cli', 'appServer', 'vscode')
            order by updated_at desc
            limit ${Math.max(1, Math.min(limit, 500))};
          `,
        ],
        {
          encoding: "utf8",
          maxBuffer: 8 * 1024 * 1024,
        }
      );

      return JSON.parse(raw || "[]") as CodexThreadRegistryRow[];
    } catch {
      return [];
    }
  }

  private threadSummaryFromCodexRegistryRow(row: CodexThreadRegistryRow): ThreadSummary | null {
    if (typeof row.id !== "string" || row.id.length === 0) {
      return null;
    }

    const backend = this.backendForId("codex").summary;
    const updatedAt = this.normalizeCodexRegistryUpdatedAt(row.updated_at) || Date.now();
    const name = this.codexComputedThreadName(row);
    const previewCandidate =
      typeof row.first_user_message === "string" && row.first_user_message.trim().length > 0
        ? row.first_user_message
        : row.title;
    const status = this.preferredThreadStatus(null, null, updatedAt, {
      preferRecentIdle: this.previewText(previewCandidate) === this.previewText(name),
    });

    return {
      id: row.id,
      name,
      preview: codexThreadPreviewForDisplay(
        this.previewText(previewCandidate) || name || "Codex CLI session",
        updatedAt
      ),
      cwd: typeof row.cwd === "string" ? row.cwd : "",
      workspacePath: null,
      status,
      updatedAt,
      sourceKind: this.codexThreadSource(row),
      launchSource: null,
      backendId: backend.id,
      backendLabel: backend.label,
      backendKind: backend.kind,
      controller: null,
    };
  }

  private codexComputedThreadName(row: CodexThreadRegistryRow): string | null {
    return preferredCodexThreadName(
      typeof row.title === "string" ? row.title : null,
      typeof row.first_user_message === "string" ? row.first_user_message : null
    );
  }

  private codexThreadSource(row: CodexThreadRegistryRow): string {
    return typeof row.source === "string" ? row.source.trim().toLowerCase() : "cli";
  }

  private normalizeCodexRegistryUpdatedAt(value: number | undefined): number {
    if (!value || !Number.isFinite(value)) {
      return 0;
    }

    return value > 1_000_000_000_000 ? value : value * 1000;
  }

  private unarchiveCodexThreadInStateDatabase(threadId: string): void {
    const escapedThreadId = threadId.replace(/'/g, "''");
    execFileSync(
      "sqlite3",
      [
        path.join(homedir(), ".codex", "state_5.sqlite"),
        `update threads
           set archived = 0,
               archived_at = null
         where id = '${escapedThreadId}';`,
      ],
      {
        encoding: "utf8",
        maxBuffer: 1024 * 1024,
      }
    );
  }

  private backendForId(backendId: string): AgentBackend {
    const backend = this.backends.get(backendId);
    if (!backend) {
      throw new HttpError(400, `Unknown backend: ${backendId}`);
    }

    return backend;
  }

  private backendForCreateRequest(body?: { backendId?: string }): AgentBackend {
    const backendId = typeof body?.backendId === "string" && body.backendId.trim().length > 0
      ? body.backendId.trim()
      : this.defaultBackendId;
    return this.backendForId(backendId);
  }

  private threadIdFromStartThreadResult(result: JSONValue | undefined): string | null {
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      return null;
    }

    if (typeof result.threadId === "string" && result.threadId.length > 0) {
      return result.threadId;
    }

    const thread = result.thread;
    if (thread && typeof thread === "object" && !Array.isArray(thread)) {
      if (typeof thread.id === "string" && thread.id.length > 0) {
        return thread.id;
      }
    }

    return null;
  }

  private backendForThread(threadId: string): AgentBackend {
    const canonicalThreadId = this.canonicalThreadId(threadId);
    const backendId = this.threadBackendIds.get(canonicalThreadId) ?? this.defaultBackendId;
    return this.backendForId(backendId);
  }

  private threadAffordancesForThread(
    backend: BackendSummary,
    summary: ThreadSummary | null = null
  ) {
    const sessionAccess = this.sessionAccessForThread(summary);
    const claudeManagedSession =
      backend.id === "claude-code" && sessionAccess === "helmManagedShell";
    return {
      canSendTurns:
        backend.id === "claude-code" ? claudeManagedSession : backend.capabilities.turnExecution,
      canInterrupt:
        backend.id === "claude-code" ? claudeManagedSession : backend.capabilities.turnInterrupt,
      canRespondToApprovals:
        backend.capabilities.approvals && backend.command.approvals === "bridgeDecisions",
      canUseRealtimeCommand: backend.capabilities.voiceCommand && backend.capabilities.realtimeVoice,
      showsOperationalSnapshot: backend.command.routing === "threadTurns",
      sessionAccess,
      notes: this.threadNotesForThread(backend, sessionAccess),
    };
  }

  private sessionAccessForThread(
    summary: ThreadSummary | null
  ): "helmManagedShell" | "cliAttach" | "editorResume" | "sharedThread" {
    if (isHelmManagedLaunchSource(summary?.launchSource)) {
      return "helmManagedShell";
    }

    switch (summary?.sourceKind) {
      case "cli":
        return "cliAttach";
      case "vscode":
      case "claude-desktop":
        return "editorResume";
      default:
        return "sharedThread";
    }
  }

  private threadNotesForThread(
    backend: BackendSummary,
    sessionAccess: "helmManagedShell" | "cliAttach" | "editorResume" | "sharedThread"
  ): string {
    const noteParts = [backend.command.notes];

    switch (sessionAccess) {
      case "helmManagedShell":
        noteParts.push(
          "This session was launched through helm integration, so you can move between the CLI, supported Mac apps, and helm without losing the active working context."
        );
        break;
      case "cliAttach":
        noteParts.push(
          "This session originated in the CLI and can be attached from helm, but it was not launched through helm integration."
        );
        break;
      case "editorResume":
        noteParts.push(
          "This session originated from another desktop surface, so helm keeps it on that surface and sends through the shared thread bridge."
        );
        break;
      case "sharedThread":
        noteParts.push(
          "This shared session can be continued from helm or another supported client using the same thread state."
        );
        break;
    }

    return noteParts.join(" ");
  }

  private backendForCommandRequest(input: {
    backendId?: unknown;
    threadId?: unknown;
  }): AgentBackend {
    if (typeof input.threadId === "string" && input.threadId.trim().length > 0) {
      return this.backendForThread(this.canonicalThreadId(input.threadId.trim()));
    }

    if (typeof input.backendId === "string" && input.backendId.trim().length > 0) {
      return this.backendForId(input.backendId.trim());
    }

    return this.backendForId(this.defaultBackendId);
  }

  private ensureBackendSupportsBridgeApprovals(backend: AgentBackend): void {
    if (backend.summary.command.approvals === "bridgeDecisions") {
      return;
    }

    throw new HttpError(
      501,
      `${backend.summary.label} approvals are not currently handled through helm bridge decisions`
    );
  }

  private ensureBackendSupportsVoiceCommand(backend: AgentBackend): void {
    if (backend.summary.capabilities.voiceCommand) {
      return;
    }

    throw new HttpError(501, `${backend.summary.label} does not currently support Command voice routing`);
  }

  private ensureBackendSupportsRealtimeVoice(backend: AgentBackend): void {
    if (backend.summary.capabilities.realtimeVoice) {
      return;
    }

    throw new HttpError(501, `${backend.summary.label} does not currently support Realtime Command voice`);
  }

  private isPublicRoute(path: string): boolean {
    return path === "/health" || path === "/api/pairing";
  }

  private extractBearerToken(authorization: string | undefined): string | null {
    if (!authorization) {
      return null;
    }

    const trimmed = authorization.trim();
    if (!trimmed) {
      return null;
    }

    if (trimmed.toLowerCase().startsWith("bearer ")) {
      const token = trimmed.slice(7).trim();
      return token.length > 0 ? token : null;
    }

    return null;
  }

  private isLoopbackRequest(req: express.Request): boolean {
    const forwarded = req.headers["x-forwarded-for"];
    const forwardedValue =
      typeof forwarded === "string" ? forwarded.split(",")[0]?.trim() : undefined;
    const remoteAddress =
      forwardedValue ??
      req.socket.remoteAddress ??
      req.ip ??
      "";

    return this.isLoopbackAddress(remoteAddress);
  }

  private isLoopbackAddress(value: string): boolean {
    return (
      value === "127.0.0.1" ||
      value === "::1" ||
      value === "::ffff:127.0.0.1" ||
      value === "::ffff:localhost" ||
      value === "localhost"
    );
  }

  private externalBridgeURLs(): string[] {
    if (!this.isWildcardAddress(config.bridgeHost)) {
      return [];
    }

    const urls = new Set<string>();
    for (const entries of Object.values(networkInterfaces())) {
      for (const entry of entries ?? []) {
        if (entry.internal) {
          continue;
        }

        if (
          this.isWildcardAddress(entry.address) ||
          this.isLoopbackAddress(entry.address) ||
          this.isLinkLocalAddress(entry.address)
        ) {
          continue;
        }

        if (entry.family === "IPv4") {
          urls.add(`http://${entry.address}:${config.bridgePort}`);
          continue;
        }

        if (entry.family === "IPv6") {
          urls.add(`http://[${entry.address}]:${config.bridgePort}`);
        }
      }
    }

    return Array.from(urls);
  }

  private pairingBridgeURLs(): string[] {
    const urls = new Set<string>();

    if (config.bridgePreferredURL) {
      urls.add(config.bridgePreferredURL);
    }

    if (!this.isWildcardAddress(config.bridgeHost) && !this.isLoopbackAddress(config.bridgeHost)) {
      urls.add(this.buildBridgeURL(config.bridgeHost));
    }

    for (const url of this.externalBridgeURLs()) {
      urls.add(url);
    }

    urls.add(`http://127.0.0.1:${config.bridgePort}`);

    return Array.from(urls).sort(
      (lhs, rhs) => this.bridgeURLPriority(lhs) - this.bridgeURLPriority(rhs) || lhs.localeCompare(rhs)
    );
  }

  private buildPairingSetupURL(bridgeURL: string, token: string, bridgeId: string): string {
    const setupURL = new URL("helm://pair");
    setupURL.searchParams.set("bridge", bridgeURL);
    setupURL.searchParams.set("token", token);
    setupURL.searchParams.set("bridgeId", bridgeId);
    return setupURL.toString();
  }

  private isWildcardAddress(value: string): boolean {
    return value === "0.0.0.0" || value === "::" || value === "[::]";
  }

  private isLinkLocalAddress(value: string): boolean {
    const host = this.normalizeAddressHost(value).toLowerCase();
    return host.startsWith("169.254.") || host.startsWith("fe80:");
  }

  private normalizeAddressHost(value: string): string {
    if (value.startsWith("[") && value.endsWith("]")) {
      return value.slice(1, -1);
    }

    return value;
  }

  private buildBridgeURL(host: string): string {
    const normalizedHost = this.normalizeAddressHost(host);
    if (normalizedHost.includes(":")) {
      return `http://[${normalizedHost}]:${config.bridgePort}`;
    }

    return `http://${normalizedHost}:${config.bridgePort}`;
  }

  private bridgeURLPriority(value: string): number {
    try {
      const url = new URL(value);
      const host = url.hostname.toLowerCase();

      if (config.bridgePreferredURL && value === config.bridgePreferredURL) {
        return 0;
      }

      if (this.isTailscaleHost(host)) {
        return 1;
      }

      if (this.isLoopbackAddress(host)) {
        return 99;
      }

      if (this.isPrivateIPv4Host(host)) {
        return 2;
      }

      if (this.isPublicIPv4Host(host)) {
        return 3;
      }

      if (this.isUniqueLocalIPv6Host(host)) {
        return 4;
      }

      if (this.isPublicIPv6Host(host)) {
        return 5;
      }

    } catch {
      return 100;
    }

    return 50;
  }

  private isTailscaleHost(host: string): boolean {
    if (host.endsWith(".ts.net")) {
      return true;
    }

    const parts = host.split(".").map((part) => Number.parseInt(part, 10));
    if (parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)) {
      const first = parts[0] ?? -1;
      const second = parts[1] ?? -1;
      return first === 100 && second >= 64 && second <= 127;
    }

    return host.startsWith("fd7a:115c:a1e0:");
  }

  private isPrivateIPv4Host(host: string): boolean {
    const parts = host.split(".").map((part) => Number.parseInt(part, 10));
    if (parts.length !== 4 || !parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)) {
      return false;
    }

    const first = parts[0] ?? -1;
    const second = parts[1] ?? -1;

    if (first === 10) {
      return true;
    }

    if (first === 172 && second >= 16 && second <= 31) {
      return true;
    }

    return first === 192 && second === 168;
  }

  private isPublicIPv4Host(host: string): boolean {
    const parts = host.split(".").map((part) => Number.parseInt(part, 10));
    return parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255);
  }

  private isUniqueLocalIPv6Host(host: string): boolean {
    return host.startsWith("fc") || host.startsWith("fd");
  }

  private isPublicIPv6Host(host: string): boolean {
    return host.includes(":") && !this.isLinkLocalAddress(host) && !this.isUniqueLocalIPv6Host(host);
  }

  private requireClientIdentity(body?: {
    clientId?: string;
    clientName?: string;
    force?: boolean;
  }): { clientId: string; clientName: string; force: boolean } {
    const clientId = String(body?.clientId ?? "").trim();
    if (!clientId) {
      throw new HttpError(400, "clientId is required");
    }

    const clientName = String(body?.clientName ?? "").trim() || "Unknown helm Client";
    return {
      clientId,
      clientName,
      force: Boolean(body?.force),
    };
  }

  private claimThreadControl(
    threadId: string,
    body?: {
      clientId?: string;
      clientName?: string;
      force?: boolean;
    }
  ) {
    const identity = this.requireClientIdentity(body);
    try {
      return this.controllers.claim({
        threadId,
        clientId: identity.clientId,
        clientName: identity.clientName,
        force: identity.force,
      });
    } catch (error) {
      if (error instanceof Error) {
        throw new HttpError(409, error.message);
      }
      throw error;
    }
  }

  private releaseThreadControl(
    threadId: string,
    body?: {
      clientId?: string;
      clientName?: string;
      force?: boolean;
    }
  ): void {
    const identity = this.requireClientIdentity(body);
    try {
      this.controllers.release(threadId, identity.clientId, identity.force);
    } catch (error) {
      if (error instanceof Error) {
        throw new HttpError(409, error.message);
      }
      throw error;
    }
  }

  private ensureThreadControl(
    threadId: string,
    body?: {
      clientId?: string;
      clientName?: string;
      force?: boolean;
    }
  ): void {
    this.claimThreadControl(threadId, body);
    void this.broadcastControlChange(threadId);
  }

  private ensureThreadControlForCommand(
    threadId: string,
    body?: {
      clientId?: string;
      clientName?: string;
      force?: boolean;
    }
  ): void {
    this.ensureThreadControl(threadId, {
      ...body,
      force: true,
    });
  }

  private async broadcastControlChange(threadId: string): Promise<void> {
    this.broadcast({
      type: "helm.control.changed",
      payload: {
        threadId,
        controller: this.controllers.get(threadId),
      },
    });
  }

  private broadcastRuntimeThread(threadId: string): void {
    const thread = this.runtime.get(threadId);
    if (!thread) {
      return;
    }

    this.broadcast({
      type: "helm.runtime.thread",
      payload: {
        thread,
      },
    });
  }

  private broadcast(payload: unknown): void {
    let envelope = this.asRealtimeEnvelope(payload);
    if (!envelope) {
      return;
    }
    let text = this.serializeRealtimePayload(envelope, 0);
    const byteLength = Buffer.byteLength(text, "utf8");
    if (byteLength > BridgeServer.MAX_WS_OUTBOUND_MESSAGE_BYTES) {
      const compactPayload = this.compactOversizedBroadcastPayload(payload);
      if (compactPayload) {
        envelope = this.asRealtimeEnvelope(compactPayload);
        if (!envelope) {
          return;
        }
        text = this.serializeRealtimePayload(envelope, 0);
        const compactByteLength = Buffer.byteLength(text, "utf8");
        if (compactByteLength <= BridgeServer.MAX_WS_OUTBOUND_MESSAGE_BYTES) {
          this.sendReplayableRealtimePayload(envelope);
          return;
        }
      }

      const payloadType =
        typeof payload === "object" &&
        payload !== null &&
        "type" in payload &&
        typeof (payload as { type?: unknown }).type === "string"
          ? (payload as { type: string }).type
          : "unknown";
      console.warn(
        `[bridge] dropping oversized websocket frame type=${payloadType} bytes=${byteLength} max=${BridgeServer.MAX_WS_OUTBOUND_MESSAGE_BYTES}`
      );
      return;
    }

    this.sendReplayableRealtimePayload(envelope);
  }

  private sendBroadcastText(text: string): void {
    for (const client of this.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(text);
      }
    }
  }

  private compactOversizedBroadcastPayload(payload: unknown): unknown | null {
    if (!this.isThreadDetailBroadcastPayload(payload)) {
      return null;
    }

    return {
      type: "helm.thread.detail",
      payload: {
        thread: this.compactThreadDetailForWebSocket(payload.payload.thread),
      },
    };
  }

  private isThreadDetailBroadcastPayload(
    payload: unknown
  ): payload is { type: "helm.thread.detail"; payload: { thread: ThreadDetail } } {
    if (typeof payload !== "object" || payload === null) {
      return false;
    }

    const envelope = payload as {
      type?: unknown;
      payload?: {
        thread?: {
          id?: unknown;
          turns?: unknown;
        };
      };
    };

    return envelope.type === "helm.thread.detail"
      && typeof envelope.payload?.thread?.id === "string"
      && Array.isArray(envelope.payload.thread.turns);
  }

  private asRealtimeEnvelope(payload: unknown): Record<string, unknown> | null {
    return typeof payload === "object" && payload !== null && !Array.isArray(payload)
      ? payload as Record<string, unknown>
      : null;
  }

  private serializeRealtimePayload(payload: Record<string, unknown>, sequence: number): string {
    return JSON.stringify({
      ...payload,
      sequence,
    });
  }

  private sendReplayableRealtimePayload(payload: Record<string, unknown>): void {
    const record = this.realtimeEvents.publish(payload);
    this.sendBroadcastText(record.text);
  }

  private commandExecutionDetail(value: { [key: string]: JSONValue }): string | null {
    const cwd = typeof value.cwd === "string" ? value.cwd : null;
    const output =
      this.bestDetail(value.aggregatedOutput) ??
      this.bestDetail(value.stdout) ??
      this.bestDetail(value.stderr);
    const exitCode =
      typeof value.exitCode === "number" ? `exit code ${value.exitCode}` : null;

    return [cwd, exitCode, output].filter((entry): entry is string => Boolean(entry)).join(" | ") || null;
  }

  private commandExecutionMetadataSummary(value: { [key: string]: JSONValue }): string | null {
    const parts: string[] = [];
    const cwd = typeof value.cwd === "string" ? value.cwd : null;
    const exitCode = typeof value.exitCode === "number" ? value.exitCode : null;
    const status = typeof value.status === "string" ? value.status : null;

    if (cwd) {
      parts.push(`cwd ${cwd}`);
    }

    if (status) {
      parts.push(`status ${status}`);
    }

    if (typeof exitCode === "number") {
      parts.push(`exit ${exitCode}`);
    }

    return parts.join(" | ") || null;
  }

  private fileChangeDetail(changes: JSONValue | undefined): string | null {
    if (!Array.isArray(changes) || changes.length === 0) {
      return null;
    }

    const kindCounts = new Map<string, number>();
    const paths = changes
      .map((change) => {
        const kind = this.extractStringByKeys(change, [
          "kind",
          "changeType",
          "operation",
          "status",
          "mode",
          "type",
        ]);
        if (kind) {
          const label = this.humanizeChangeKind(kind);
          kindCounts.set(label, (kindCounts.get(label) ?? 0) + 1);
        }

        return this.extractStringByKeys(change, ["path", "filePath", "relativePath"]);
      })
      .filter((path): path is string => typeof path === "string" && path.length > 0);

    const countSummary = `${changes.length} file change${changes.length === 1 ? "" : "s"}`;
    const kindSummary = Array.from(kindCounts.entries())
      .sort((lhs, rhs) => rhs[1] - lhs[1])
      .slice(0, 3)
      .map(([kind, count]) => `${count} ${kind}`)
      .join(", ");

    if (paths.length === 0) {
      return [countSummary, kindSummary].filter(Boolean).join(" | ") || countSummary;
    }

    const preview = paths.slice(0, 3).join(", ");
    const remainder = paths.length > 3 ? ` +${paths.length - 3} more` : "";
    return [countSummary, kindSummary, preview + remainder].filter(Boolean).join(" | ");
  }

  private fileChangeRawText(changes: JSONValue | undefined): string | null {
    if (!Array.isArray(changes) || changes.length === 0) {
      return null;
    }

    const lines = changes
      .map((change) => {
        const path = this.extractStringByKeys(change, ["path", "filePath", "relativePath"]);
        const kind = this.extractStringByKeys(change, [
          "kind",
          "changeType",
          "operation",
          "status",
          "mode",
          "type",
        ]);
        const diff = this.extractStringByKeys(change, [
          "diff",
          "unified_diff",
          "unifiedDiff",
          "patch",
        ]);

        if (!path && !kind && !diff) {
          return null;
        }

        if (diff) {
          return this.formattedFileChangeDiff({
            path,
            kind,
            diff,
          });
        }

        return this.fileChangeHeadline(path, kind);
      })
      .filter((line): line is string => typeof line === "string" && line.length > 0);

    return lines.length > 0 ? lines.join("\n") : null;
  }

  private formattedFileChangeDiff(change: {
    path: string | null;
    kind: string | null;
    diff: string;
  }): string {
    const normalizedDiff = change.diff
      .replace(/\r\n/g, "\n")
      .replace(/\r/g, "\n")
      .trim();
    const headline = this.fileChangeHeadline(change.path, change.kind);

    if (!normalizedDiff) {
      return headline ?? "";
    }

    if (normalizedDiff.startsWith("diff --git")) {
      return normalizedDiff;
    }

    if (headline) {
      return `${headline}\n${normalizedDiff}`;
    }

    return normalizedDiff;
  }

  private fileChangeHeadline(path: string | null, kind: string | null): string | null {
    const humanKind = kind ? this.humanizeChangeKind(kind) : null;
    return [humanKind, path]
      .filter((entry): entry is string => Boolean(entry))
      .join(" ") || null;
  }

  private fileChangeMetadataSummary(changes: JSONValue | undefined): string | null {
    if (!Array.isArray(changes) || changes.length === 0) {
      return null;
    }

    return `${changes.length} change${changes.length === 1 ? "" : "s"} recorded`;
  }

  private toolMetadataSummary(value: { [key: string]: JSONValue }): string | null {
    const parts: string[] = [];
    const server = typeof value.server === "string" ? value.server : null;
    const tool = typeof value.tool === "string" ? value.tool : null;
    const status = typeof value.status === "string" ? value.status : null;

    if (server) {
      parts.push(server);
    }

    if (tool) {
      parts.push(tool);
    }

    if (status) {
      parts.push(`status ${status}`);
    }

    return parts.join(" | ") || null;
  }

  private webSearchMetadataSummary(value: { [key: string]: JSONValue }): string | null {
    const query = typeof value.query === "string" ? value.query : null;
    const status = typeof value.status === "string" ? value.status : null;
    return [query ? `query ${query}` : null, status ? `status ${status}` : null]
      .filter((entry): entry is string => Boolean(entry))
      .join(" | ") || null;
  }

  private genericMetadataSummary(value: { [key: string]: JSONValue }): string | null {
    const status = this.extractStringByKeys(value, ["status", "phase"]);
    return status ? `status ${status}` : null;
  }

  private permissionApprovalDetail(value: JSONValue | undefined): string | null {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return null;
    }

    const reason = this.extractStringByKeys(value, ["reason", "message", "summary"]);
    const command = this.extractStringByKeys(value, ["command"]);
    const grantRoot = this.extractStringByKeys(value, ["grantRoot", "cwd"]);
    const parts = [
      reason,
      command ? `command ${command}` : null,
      grantRoot ? `scope ${grantRoot}` : null,
    ].filter((entry): entry is string => Boolean(entry));

    return parts.join(" | ") || this.bestDetail(value);
  }

  private humanizeChangeKind(kind: string): string {
    const lower = kind.trim().toLowerCase();
    switch (lower) {
      case "a":
      case "add":
      case "added":
      case "create":
      case "created":
        return "added";
      case "d":
      case "delete":
      case "deleted":
      case "remove":
      case "removed":
        return "deleted";
      case "r":
      case "rename":
      case "renamed":
        return "renamed";
      case "m":
      case "modify":
      case "modified":
      case "update":
      case "updated":
        return "modified";
      default:
        return lower;
    }
  }

  private terminalInputSequenceFromRequest(body: unknown): string | null {
    const record = body && typeof body === "object"
      ? body as { input?: unknown; inputs?: unknown }
      : {};
    const rawInputs = Array.isArray(record.inputs) ? record.inputs : [record.input];
    const sequences: string[] = [];

    for (const rawInput of rawInputs) {
      const sequence = this.terminalInputSequence(String(rawInput ?? ""));
      if (!sequence) {
        return null;
      }
      sequences.push(sequence);
    }

    return sequences.length > 0 ? sequences.join("") : null;
  }

  private turnDeliveryModeFromRequest(body: unknown): TurnDeliveryMode {
    const record = body && typeof body === "object"
      ? body as { deliveryMode?: unknown }
      : {};
    const value = typeof record.deliveryMode === "string"
      ? record.deliveryMode.trim().toLowerCase()
      : "";

    switch (value) {
      case "":
      case "queue":
        return "queue";
      case "steer":
      case "now":
      case "sendimmediately":
      case "send-immediately":
      case "immediate":
        return "steer";
      case "interrupt":
        console.warn("[bridge] /api/threads/:threadId/turns no longer accepts interrupting text delivery; steering the active turn instead. Use /interrupt for explicit interrupts.");
        return "steer";
      default:
        throw new HttpError(400, "Unsupported turn delivery mode");
    }
  }

  private async imageAttachmentsFromRequest(body: unknown): Promise<StartTurnImageAttachment[]> {
    const record = body && typeof body === "object"
      ? body as { attachments?: unknown; imageAttachments?: unknown }
      : {};
    const rawAttachments = Array.isArray(record.attachments)
      ? record.attachments
      : Array.isArray(record.imageAttachments)
        ? record.imageAttachments
        : [];

    if (rawAttachments.length === 0) {
      return [];
    }

    if (rawAttachments.length > BridgeServer.TURN_IMAGE_MAX_ATTACHMENTS) {
      throw new HttpError(413, `At most ${BridgeServer.TURN_IMAGE_MAX_ATTACHMENTS} images can be attached to one turn.`);
    }

    const folder = path.join(homedir(), ".config", "helm", "mobile-attachments");
    await mkdir(folder, { recursive: true });

    let totalBytes = 0;
    const attachments: StartTurnImageAttachment[] = [];
    for (const rawAttachment of rawAttachments) {
      if (!rawAttachment || typeof rawAttachment !== "object" || Array.isArray(rawAttachment)) {
        throw new HttpError(400, "Invalid image attachment");
      }

      const attachment = rawAttachment as {
        data?: unknown;
        base64?: unknown;
        mimeType?: unknown;
        filename?: unknown;
      };
      const base64 = typeof attachment.data === "string"
        ? attachment.data
        : typeof attachment.base64 === "string"
          ? attachment.base64
          : "";
      const mimeType = typeof attachment.mimeType === "string"
        ? attachment.mimeType.trim().toLowerCase()
        : "image/jpeg";
      if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
        throw new HttpError(400, `Unsupported image attachment type: ${mimeType}`);
      }

      const normalizedBase64 = base64.includes(",") ? base64.split(",").pop() ?? "" : base64;
      const bytes = Buffer.from(normalizedBase64, "base64");
      if (bytes.length === 0) {
        throw new HttpError(400, "Image attachment is empty.");
      }
      if (bytes.length > BridgeServer.TURN_IMAGE_MAX_BYTES) {
        throw new HttpError(413, "Image attachment is too large.");
      }
      totalBytes += bytes.length;
      if (totalBytes > BridgeServer.TURN_IMAGE_TOTAL_MAX_BYTES) {
        throw new HttpError(413, "Image attachments are too large.");
      }

      const extension = this.imageExtensionForMimeType(mimeType);
      const filename = this.safeAttachmentFilename(
        typeof attachment.filename === "string" ? attachment.filename : null,
        extension
      );
      const localPath = path.join(folder, `${Date.now()}-${randomUUID()}-${filename}`);
      await writeFile(localPath, bytes, { mode: 0o600 });
      attachments.push({
        path: localPath,
        filename,
        mimeType,
      });
    }

    return attachments;
  }

  private async fileAttachmentsFromRequest(body: unknown): Promise<StartTurnFileAttachment[]> {
    const record = body && typeof body === "object"
      ? body as { fileAttachments?: unknown }
      : {};
    const rawAttachments = Array.isArray(record.fileAttachments) ? record.fileAttachments : [];

    if (rawAttachments.length === 0) {
      return [];
    }

    if (rawAttachments.length > BridgeServer.TURN_FILE_MAX_ATTACHMENTS) {
      throw new HttpError(413, `At most ${BridgeServer.TURN_FILE_MAX_ATTACHMENTS} files can be attached to one turn.`);
    }

    const folder = path.join(homedir(), ".config", "helm", "mobile-attachments", "files");
    await mkdir(folder, { recursive: true });

    let totalBytes = 0;
    const attachments: StartTurnFileAttachment[] = [];
    for (const rawAttachment of rawAttachments) {
      if (!rawAttachment || typeof rawAttachment !== "object" || Array.isArray(rawAttachment)) {
        throw new HttpError(400, "Invalid file attachment");
      }

      const attachment = rawAttachment as {
        data?: unknown;
        base64?: unknown;
        mimeType?: unknown;
        filename?: unknown;
      };
      const base64 = typeof attachment.data === "string"
        ? attachment.data
        : typeof attachment.base64 === "string"
          ? attachment.base64
          : "";
      const normalizedBase64 = base64.includes(",") ? base64.split(",").pop() ?? "" : base64;
      const bytes = Buffer.from(normalizedBase64, "base64");
      if (bytes.length === 0) {
        throw new HttpError(400, "File attachment is empty.");
      }
      if (bytes.length > BridgeServer.TURN_FILE_MAX_BYTES) {
        throw new HttpError(413, "File attachment is too large.");
      }
      totalBytes += bytes.length;
      if (totalBytes > BridgeServer.TURN_FILE_TOTAL_MAX_BYTES) {
        throw new HttpError(413, "File attachments are too large.");
      }

      const mimeType = typeof attachment.mimeType === "string" && attachment.mimeType.trim()
        ? attachment.mimeType.trim().toLowerCase()
        : "application/octet-stream";
      const filename = this.safeAttachmentFilename(
        typeof attachment.filename === "string" ? attachment.filename : null,
        "dat",
        "file"
      );
      const localPath = path.join(folder, `${Date.now()}-${randomUUID()}-${filename}`);
      await writeFile(localPath, bytes, { mode: 0o600 });
      attachments.push({
        path: localPath,
        filename,
        mimeType,
      });
    }

    return attachments;
  }

  private imageExtensionForMimeType(mimeType: string): string {
    switch (mimeType) {
      case "image/png":
        return "png";
      case "image/webp":
        return "webp";
      case "image/jpeg":
      default:
        return "jpg";
    }
  }

  private safeAttachmentFilename(filename: string | null, extension: string, fallbackBase = "image"): string {
    const fallback = `${fallbackBase}.${extension}`;
    if (!filename) {
      return fallback;
    }

    const base = path.basename(filename)
      .replace(/[^A-Za-z0-9._-]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 80);
    if (!base) {
      return fallback;
    }
    if (/\.[A-Za-z0-9]{2,5}$/.test(base)) {
      return base;
    }
    return `${base}.${extension}`;
  }

  private terminalInputSequence(input: string): string | null {
    switch (input) {
      case "arrowUp":
        return "\x1b[A";
      case "arrowDown":
        return "\x1b[B";
      case "arrowRight":
        return "\x1b[C";
      case "arrowLeft":
        return "\x1b[D";
      case "enter":
        return "\r";
      case "space":
        return " ";
      case "tab":
        return "\t";
      case "escape":
        return "\x1b";
      default:
        return null;
    }
  }

  private handleError(response: express.Response, error: unknown): void {
    if (error instanceof HttpError) {
      response.status(error.status).json({ error: error.message });
      return;
    }

    const message = error instanceof Error ? error.message : "Unknown error";
    response.status(500).json({ error: message });
  }
}

type DirectorySuggestion = {
  path: string;
  displayPath: string;
  isExact: boolean;
};

type FileTagSuggestion = {
  path: string;
  displayPath: string;
  completion: string;
  isDirectory: boolean;
};

type SkillSuggestion = {
  name: string;
  summary: string;
  path: string;
};

const FILE_TAG_IGNORED_NAMES = new Set([
  ".git",
  ".runtime",
  ".xcodebuildmcp",
  "build",
  "DerivedData",
  "node_modules",
]);

function expandUserPath(input: string): string {
  const trimmed = input.trim();
  if (trimmed === "~") {
    return process.env.HOME ?? trimmed;
  }
  if (trimmed.startsWith("~/")) {
    return path.join(process.env.HOME ?? "~", trimmed.slice(2));
  }
  return trimmed;
}

function displayPathForSuggestion(input: string, preferTilde: boolean): string {
  if (!preferTilde) {
    return input;
  }
  const home = process.env.HOME;
  if (home && input.startsWith(`${home}/`)) {
    return `~/${input.slice(home.length + 1)}`;
  }
  if (home && input === home) {
    return "~";
  }
  return input;
}

async function listDirectorySuggestions(prefix: string): Promise<DirectorySuggestion[]> {
  const rawPrefix = prefix.trim();
  const expanded = expandUserPath(prefix);
  const resolvedInput = expanded.length > 0 ? path.resolve(expanded) : (process.env.HOME ?? "/");
  const endsWithSeparator = /[\\/]$/.test(expanded);
  const basenamePrefix = endsWithSeparator ? "" : path.basename(resolvedInput);
  const preferTilde = rawPrefix.length === 0 || rawPrefix === "~" || rawPrefix.startsWith("~/");
  const exactDirectory = await resolveExistingDirectoryPath(resolvedInput);

  if (exactDirectory && !endsWithSeparator) {
    const childDirectories = await childDirectorySuggestions(exactDirectory, preferTilde);
    return [
      {
        path: exactDirectory,
        displayPath: displayPathForSuggestion(exactDirectory, preferTilde),
        isExact: true,
      },
      ...childDirectories,
    ].slice(0, 24);
  }

  const parentSeed = endsWithSeparator ? resolvedInput : path.dirname(resolvedInput);
  const parentDirectory = await resolveExistingDirectoryPath(parentSeed);
  if (!parentDirectory) {
    return [];
  }

  let entries;
  try {
    entries = await readdir(parentDirectory, { withFileTypes: true });
  } catch {
    return [];
  }

  const suggestions = entries
    .filter((entry) => entry.isDirectory())
    .filter((entry) => {
      return basenamePrefix.length === 0 || entry.name.toLowerCase().startsWith(basenamePrefix.toLowerCase());
    })
    .map((entry) => path.join(parentDirectory, entry.name))
    .sort((lhs, rhs) => lhs.localeCompare(rhs))
    .slice(0, 24)
    .map((entryPath) => ({
      path: entryPath,
      displayPath: displayPathForSuggestion(entryPath, preferTilde),
      isExact: exactDirectory != null && entryPath === exactDirectory,
    }));

  if (exactDirectory && suggestions.every((entry) => entry.path !== exactDirectory)) {
    suggestions.unshift({
      path: exactDirectory,
      displayPath: displayPathForSuggestion(exactDirectory, preferTilde),
      isExact: true,
    });
  }

  return suggestions;
}

async function listFileTagSuggestions(cwd: string, prefix: string): Promise<FileTagSuggestion[]> {
  const root = await resolveExistingDirectoryPath(expandUserPath(cwd));
  if (!root) {
    return [];
  }

  const rawPrefix = prefix.trim().replace(/^@/, "");
  const expandedPrefix = expandUserPath(rawPrefix);
  const absoluteInput = path.isAbsolute(expandedPrefix)
    ? path.resolve(expandedPrefix)
    : path.resolve(root, expandedPrefix);
  const endsWithSeparator = rawPrefix.length > 0 && /[\\/]$/.test(rawPrefix);
  const basenamePrefix = endsWithSeparator ? "" : path.basename(absoluteInput);
  const parentSeed = endsWithSeparator ? absoluteInput : path.dirname(absoluteInput);
  const parentDirectory = rawPrefix.length === 0 ? root : await resolveExistingDirectoryPath(parentSeed);
  if (!parentDirectory) {
    return [];
  }

  let entries;
  try {
    entries = await readdir(parentDirectory, { withFileTypes: true });
  } catch {
    return [];
  }

  const preferAbsolute = rawPrefix.startsWith("/") || rawPrefix.startsWith("~/");
  return entries
    .filter((entry) => !FILE_TAG_IGNORED_NAMES.has(entry.name))
    .filter((entry) => {
      return basenamePrefix.length === 0 || entry.name.toLowerCase().startsWith(basenamePrefix.toLowerCase());
    })
    .filter((entry) => entry.isDirectory() || entry.isFile() || entry.isSymbolicLink())
    .map((entry) => {
      const entryPath = path.join(parentDirectory, entry.name);
      const isDirectory = entry.isDirectory();
      const completion = fileTagCompletion(entryPath, root, preferAbsolute, isDirectory);
      return {
        path: entryPath,
        displayPath: completion,
        completion,
        isDirectory,
      };
    })
    .sort((lhs, rhs) => {
      if (lhs.isDirectory !== rhs.isDirectory) {
        return lhs.isDirectory ? -1 : 1;
      }
      return lhs.completion.localeCompare(rhs.completion);
    })
    .slice(0, 24);
}

function fileTagCompletion(entryPath: string, root: string, preferAbsolute: boolean, isDirectory: boolean): string {
  const normalizedEntry = path.resolve(entryPath);
  const normalizedRoot = path.resolve(root);
  let completion: string;

  if (!preferAbsolute && (normalizedEntry === normalizedRoot || normalizedEntry.startsWith(`${normalizedRoot}${path.sep}`))) {
    completion = path.relative(normalizedRoot, normalizedEntry) || ".";
  } else {
    completion = displayPathForSuggestion(normalizedEntry, true);
  }

  return isDirectory && !completion.endsWith("/") ? `${completion}/` : completion;
}

async function listSkillSuggestions(prefix: string, cwd: string): Promise<SkillSuggestion[]> {
  const normalizedPrefix = prefix.trim().replace(/^\$/, "").toLowerCase();
  const roots = skillRoots(cwd);
  const skills = new Map<string, SkillSuggestion>();

  for (const root of roots) {
    for (const skill of await readSkillsUnder(root)) {
      if (!normalizedPrefix || skill.name.toLowerCase().startsWith(normalizedPrefix)) {
        if (!skills.has(skill.name)) {
          skills.set(skill.name, skill);
        }
      }
    }
  }

  return Array.from(skills.values())
    .sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
    .slice(0, 24);
}

function skillRoots(cwd: string): string[] {
  const roots = new Set<string>();
  const codexHome = process.env.CODEX_HOME?.trim() || path.join(homedir(), ".codex");
  roots.add(path.join(codexHome, "skills"));

  const expandedCwd = expandUserPath(cwd);
  if (expandedCwd) {
    roots.add(path.join(path.resolve(expandedCwd), ".codex", "skills"));
  }

  return Array.from(roots);
}

async function readSkillsUnder(root: string, depth = 0): Promise<SkillSuggestion[]> {
  if (depth > 3) {
    return [];
  }

  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }

  const skillFile = entries.find((entry) => entry.isFile() && entry.name === "SKILL.md");
  if (skillFile) {
    const skill = await readSkillFile(path.join(root, skillFile.name));
    return skill ? [skill] : [];
  }

  const nested = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory())
      .map((entry) => readSkillsUnder(path.join(root, entry.name), depth + 1))
  );
  return nested.flat();
}

async function readSkillFile(filePath: string): Promise<SkillSuggestion | null> {
  let content: string;
  try {
    content = await readFile(filePath, "utf8");
  } catch {
    return null;
  }

  const name = frontMatterValue(content, "name") ?? path.basename(path.dirname(filePath));
  const summary = frontMatterValue(content, "description") ?? "";
  return {
    name,
    summary,
    path: filePath,
  };
}

function frontMatterValue(content: string, key: string): string | null {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = content.match(new RegExp(`^${escapedKey}:\\s*(.+)$`, "m"));
  const value = match?.[1]?.trim();
  if (!value) {
    return null;
  }
  return value.replace(/^["']|["']$/g, "");
}

async function resolveExistingDirectoryPath(input: string): Promise<string | null> {
  const absolute = path.resolve(input);
  const root = path.parse(absolute).root || "/";

  if (absolute === root) {
    return root;
  }

  const segments = absolute.slice(root.length).split(path.sep).filter(Boolean);
  let current = root;

  for (const segment of segments) {
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch {
      return null;
    }

    const match =
      entries.find((entry) => entry.name === segment) ??
      entries.find((entry) => entry.name.toLowerCase() === segment.toLowerCase());
    if (!match || !match.isDirectory()) {
      return null;
    }

    current = path.join(current, match.name);
  }

  return current;
}

async function childDirectorySuggestions(
  parentDirectory: string,
  preferTilde: boolean
): Promise<DirectorySuggestion[]> {
  let entries;
  try {
    entries = await readdir(parentDirectory, { withFileTypes: true });
  } catch {
    return [];
  }

  return entries
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(parentDirectory, entry.name))
    .sort((lhs, rhs) => lhs.localeCompare(rhs))
    .slice(0, 23)
    .map((entryPath) => ({
      path: entryPath,
      displayPath: displayPathForSuggestion(entryPath, preferTilde),
      isExact: false,
    }));
}
