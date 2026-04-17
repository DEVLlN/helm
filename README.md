# Helm

Helm is the product name.

`helm-dev` is the repository name.

Helm is an iPhone-first remote control app for Codex with a Command layer aimed at a one-system workflow:

- speak a command
- let Codex do the work
- hear a short confirmation back
- inspect the full terminal/chat output separately in the app or CLI

Helm cannot stop at Command. The iPhone remote surface also needs to expose the deeper shared-session control model: keyboard input, session output, approvals, hooks, skills, tool activity, and thread handoff with the CLI.

Helm should feel fast, reliable, and responsive across every surface. That is a product requirement, not a later optimization pass.

Helm is Codex-first today, but the control plane now supports more than one runtime path. Codex remains the deepest integration, Claude Code and Grok can run as Helm-managed terminal sessions, and local Gemma/Qwen profiles can run through Ollama. The long-term direction is one shared control plane for agent work across devices and across multiple model backends as stronger systems ship. Command should stay coherent even as backend capabilities evolve.

Voice should follow the same pattern. OpenAI Realtime is the default live path today, but Helm should eventually support alternate voice harnesses such as NVIDIA PersonaPlex when the user wants the spoken layer attached to a different preferred backend or a self-hosted voice stack.

Planned Helm surfaces:

- iPhone for full remote control and Command
- macOS for background local Command
- Apple Watch for quick status and approvals
- CarPlay for hands-free Command handoff and driving-safe alerts

Planned backend direction:

- Codex first
- Claude Code managed-terminal support
- Grok managed-terminal support
- local Gemma and Qwen profiles through Ollama
- OpenCode later
- Gemini later
- future backend support as stronger model systems become practical

Planned voice-provider direction:

- OpenAI Realtime first
- PersonaPlex later as an optional self-hosted duplex speech harness
- future backend-native or provider-native voice paths where they are strong enough to preserve Helm Command semantics

This repository is intentionally split into four parts:

- `bridge/`: a local daemon that connects to `codex app-server`, exposes mobile-safe HTTP/WebSocket APIs, and mints OpenAI Realtime client secrets for future full-duplex speech
- `ios/`: a SwiftUI iPhone app for remote sessions, approvals, turn control, notifications, and Command
- `macos/`: a SwiftUI menu bar app for background Command presence on the Mac
- `watchos/`: a thin watchOS client for session status and quick approvals

Prototype validation steps live in `TESTING.md`.

Feedback workflow steps live in `FEEDBACK.md`.

Infrastructure-prompt workflow lives in `docs/master-infra-prompt.md`.
## Current features

This is an actively working alpha. It currently includes:

- a working bridge around `codex app-server`
- bridge startup support for either a standalone `codex` CLI or the embedded runtime bundled inside `Codex.app`
- a backend-aware bridge surface with backend metadata and discovery groundwork for future multi-model expansion
- backend discovery and capability summaries in iPhone and Mac settings, plus default backend selection for new sessions
- richer backend Command semantics for routing, approvals, handoff, and voice paths so Helm can express operational differences without forking the UX
- a local Codex session-discovery fallback so CLI-started threads still appear even when `codex app-server` thread listing is incomplete
- a Claude Code backend that discovers local Claude desktop and CLI sessions, supports turn and interrupt control for Helm-managed Claude sessions, and only launches a managed desktop resume when the user explicitly opens that session from Helm
- a reusable managed-terminal backend for CLIs that do not expose a Codex-style app server but can run under Helm's PTY relay
- Grok CLI support through the user-installed `grok` or `grok-cli` command from `grokcli.io`
- local model launch profiles for Gemma 4 and Qwen3.5 through `ollama run`, with `HELM_GEMMA_MODEL` and `HELM_QWEN_MODEL` overrides for local tag names
- unavailable future backend stubs for OpenCode and Gemini so Helm can exercise multi-backend discovery and selection without pretending those integrations are already live
- backend-aware thread detail and Command affordances on iPhone and Mac so approvals, interrupts, operational snapshots, and voice behavior can adapt per backend instead of assuming every session behaves like Codex
- target-aware Realtime Command routing on iPhone so Live Command uses the selected thread or backend when establishing Realtime sessions through the bridge
- backend visibility on Apple Watch so cross-device handoff remains clear even as future backends arrive
- bearer-token pairing for mobile and websocket clients
- live runtime/event streaming over HTTP and WebSocket
- controller ownership and shared-thread handoff groundwork between Helm and the CLI
- approval decisions, interrupts, and thread detail reads
- an iPhone app with session control, runtime visibility, a priority attention queue, local notifications, and local speech/TTS Command
- an iPhone session-output view with terminal-style command output, tool activity, file changes, and message transcript instead of only high-level runtime cards
- mobile TUI support for Codex lifecycle rows including Working, Waiting, Spawned, Explored, Ran, Closed, agent handoffs, MCP startup progress, interrupted input, queued follow-ups, and file diff previews
- a pinned mobile working bar above the queued-message bar so running terminal state stays visible while queue state is active
- faster long-session opening on iPhone through bounded visible history and cached feed render state
- a drawer-style session home with active, recent, and archived sections, stable active-session ordering, and swipe gestures to move active sessions to recent and recent sessions to archive
- mobile composer affordances for queued sends, file attachment, camera/photo attachment, terminal-style history, and local `@` file plus `$` skill autocomplete
- a dedicated iPhone hooks-and-skills surface so MCP hook calls, dynamic tool or skill steps, and web actions are visible as first-class shared-session activity
- mobile permission approvals with explicit once or session scope where the bridge can safely answer them
- actionable iPhone lock-screen notifications with deep-link open and approval actions
- style-aware Command acknowledgements with Codex as the default voice profile
- an iPhone Realtime transcription path that opens a live OpenAI WebRTC session and hands completed transcripts into Codex Command
- bridge-backed OpenAI speech output for Realtime Command responses, with interruption when the user starts speaking again
- a bridge-authored spoken Command exchange payload on iPhone so acknowledgements, speech text, and resume intent are returned as one Command transaction instead of being stitched together entirely on-device
- a transport-owned primary spoken turn loop on iPhone so the hidden Realtime layer now handles final transcript dispatch, bridge command exchange, and spoken response playback inside one Live Command path
- backend-aware speech request plumbing on the bridge and iPhone so future non-Codex voice backends can slot under the same Command transport without changing the app-facing loop
- a documented future path for PersonaPlex as a self-hosted voice harness that can sit in front of the active backend while Helm preserves the same thread, approval, and Command model
- a bridge-side voice-provider abstraction with a working OpenAI provider, a PersonaPlex provider adapter for probing and native bootstrap metadata, and a dedicated voice-provider discovery surface
- provider-bootstrap inspection in iPhone and Mac settings so experimental voice transports can be verified before Helm proxies them directly
- a first native PersonaPlex bridge websocket proxy so Helm can broker PersonaPlex sessions once a server is configured, even before the Apple clients speak that transport directly
- a first iPhone PersonaPlex live-input prototype path through the hidden Command transport, using the Helm bridge proxy plus browser-side Opus capture
- a bridge-proxied PersonaPlex decoder asset path so the iPhone transport can load the upstream decoder worker and wasm through Helm instead of reaching around the bridge
- a first iPhone PersonaPlex provider-audio playback foundation with buffered output-node playback when the provider returns audio pages during a live session
- an experimental iPhone PersonaPlex provider-native spoken-response branch that opens a short-lived PersonaPlex text session for compact acknowledgement playback instead of forcing those responses back through Helm speech
- an app-level Realtime Command transport so spoken updates and confirmations use the same surface outside the Command tab
- a tighter iPhone Live Command loop with one-step start, dispatch state, and automatic return to listening after spoken responses
- a first-pass Live Command session phase model on iPhone so the app can show listening, sending, responding, switching, and failure states instead of only raw transport strings
- Realtime transport retargeting on iPhone so Live Command can reattach to a new shared session without forcing a full stop and manual restart
- suppression of redundant immediate “working on it” runtime chatter on iPhone when a spoken Command was just accepted, so Live Command feels less stitched together
- spoken ownership conflicts on iPhone now branch into an explicit take-over confirmation instead of collapsing into a raw bridge error
- an app-wide Live Command banner on iPhone so active Realtime Command state stays visible even when you leave the Command tab
- queued spoken Realtime updates on iPhone so acknowledgements and task events do not stomp each other during a live session
- a Codex-bound Command context on iPhone so the Command screen always shows the active target session, control state, and approval or interrupt actions instead of acting like a detached voice console
- compact Command follow-up questions when session or approval targeting is ambiguous
- App Shortcuts and Siri entry into Helm Command through the same session flow, including a dedicated shortcut for opening Command directly and auto-entering Live Command when Realtime is active
- a user setting to auto-resume Live Command whenever the Command surface is reopened in Realtime mode
- best-effort background critical spoken alerts for approvals, blockers, and completions when Helm is backgrounded or the phone is locked
- a main Sessions-screen recovery card for pairing and bridge reconnect issues so setup friction is visible without opening Settings first
- setup readiness checklists on iPhone and Mac with one-tap pairing and refresh actions
- first-run onboarding guides on iPhone and Mac with direct pairing, settings, and setup actions so Helm does not assume the user already understands the bridge model
- a QR-first pairing flow where Mac Helm renders the bridge-authored pairing QR and iPhone Helm scans it directly
- a bridge-authored Helm setup link plus suggested bridge URLs so pairing can still fall back to a link when QR is not practical
- iPhone setup-link import through the `helm://pair` scheme and clipboard so Helm mobile pairing can still be applied in one step when needed
- Mac settings support for copying the Helm setup link and adopting a suggested bridge URL directly
- a Mac pairing QR code so iPhone setup can begin by scanning instead of manually pasting a setup link
- a shell-autoinjection path for Codex CLI, Claude Code, and Grok CLI so Helm-aware wrappers can auto-start the bridge and keep runtime discovery ready without repeated manual shell setup
- a CLI pairing QR helper so terminal-based setup can print a scannable Helm pairing QR without requiring the Mac app first
- automatic Tailscale preference in the CLI bridge flow so Helm defaults to the Tailscale bridge URL when the host is already on a tailnet
- wrapper-authored runtime launch stamps and relay sockets so Helm can recognize shell-managed Codex, Claude, and Grok CLI sessions as its own attachable workflow and inject turns back into the live terminal when available
- explicit Apple-client session badges for Helm-managed CLI launches, so wrapped Codex, Claude, Grok, and local model sessions are visually distinct in the session lists
- a Mac settings flow that can install CLI helpers, enable shell autoinjection, and start bridge pairing directly from the app
- shared-thread handoff summaries across iPhone, Mac, and Apple Watch so it is explicit when a thread started in the CLI, who currently controls it, and where you can continue it next
- Codex-native git shortcuts on iPhone and Mac for status, diff summary, review, and last-commit checks
- a lightweight macOS menu bar app that acts as a Commander host for the already-open Codex CLI or Codex app session, with approval actions, system alerts, spoken updates, direct speech capture, and a dedicated Command panel
- a Mac wake policy that can automatically bring Helm Command forward when approvals or blockers need attention
- an optional Mac auto-listen wake path so Helm can immediately start listening after a blocker or approval pulls the Command panel forward
- a separate Mac preference for opening Helm Command directly into listening without coupling that behavior to attention-driven wake events
- a standby listening mode on Mac that re-arms spoken Command capture so Helm can feel more ambient between interactions
- a watchOS thin client with session list, runtime phase, quick approval actions, task submission, a live runtime websocket feed, in-app attention haptics, and local watch notifications for approvals, blockers, and completions
- a watchOS `Now` surface for the highest-priority thread with direct Continue on iPhone handoff
- explicit permission and privacy rationale in iPhone and Mac settings for bridge pairing, notifications, and speech capture
- first-pass diagnostics surfaces for snapshot, acknowledgement, and reconnect latency on iPhone, Mac, and Watch
- visible responsiveness budget health summaries on iPhone, Mac, and Watch so Helm can show when launch, snapshot, approval, and reconnect paths are healthy versus drifting out of target
- launch-ready timing samples on iPhone, Mac, and Watch so startup responsiveness is measurable
- reconnect timing samples on iPhone, Mac, and Watch so transport recovery can be tuned against real numbers
- approval timing samples on iPhone, Mac, and Watch so high-friction approval loops can be tuned separately from normal command dispatch
- automatic recovery summaries that clear themselves once Helm regains a stable live state
- reduced live-surface UI churn by debouncing thread-detail refreshes and skipping equivalent snapshot writes across iPhone, Mac, and Watch
- bounded long-running client state by pruning stale thread-detail caches and capping the iPhone Command transcript log
- lifecycle-aware startup so Helm iPhone and macOS start from the app layer instead of waiting on incidental view presentation
- explicit background suspension on iPhone and Apple Watch so live transport, speech, and reconnect work pause cleanly when the app cannot responsibly stay live
- tighter bridge request timeouts and clearer degraded-network error messages across iPhone, Mac, and Watch so network failures surface quickly instead of hanging on default system timeouts
- decoded bridge error payloads across iPhone, Mac, and Watch so control and approval failures surface as useful messages instead of raw JSON
- a generated `Helm.xcodeproj` with a successful simulator build
- a generated `HelmMac.xcodeproj` with a successful local macOS build
- a generated `HelmWatch.xcodeproj` with a successful watchOS simulator build
- a documented upgrade path to OpenAI Realtime speech
- a first voice-provider abstraction layer so execution backends and duplex speech providers can evolve independently
- a first backend abstraction layer so managed terminal runtimes, local model profiles, Claude Code, and future Gemini-style integrations can plug into the same Helm control plane

## Future features

Planned and unfinished work:

- relay infrastructure and remote networking at Remodex depth, including more robust away-from-laptop operation over private networks
- provider-native or alternate-backend speech implementations beyond the current backend-aware bridge speech path
- full live-validated app-side PersonaPlex duplex transport, including provider-native spoken runtime output and end-to-end provider-native acknowledgement behavior instead of relying on Helm-owned spoken confirmations
- deeper mobile TUI parity with upstream Codex as new lifecycle rows, tool events, and agent-status syntax ship
- deeper multi-backend execution support for Grok, local models, OpenCode, Gemini, and newer agent systems without splitting the app UX
- richer remote file, attachment, and artifact transfer between iPhone and the Mac-hosted CLI
- background Apple Watch alert delivery
- CarPlay client support
- richer always-listening desktop Command flows beyond the new standby loop
- richer diff and git action surfaces beyond the new shortcut layer

Background spoken alerts are best-effort on iPhone. Helm now has the right app-level speech routing, notification timing, and audio-session posture for them, but iOS still controls what can continue running when the app is suspended.

## Why this architecture

Codex and GPT-5.4/Codex are not exposed as native speech models. The practical design is:

1. Keep Codex as the coding/control backend.
2. Put a spoken Command layer in front of it.
3. Speak only short confirmations and status summaries.
4. Leave full textual output in the terminal and remote UI.

That same shape should eventually support multiple voice providers:

1. Helm keeps the session, approval, and Command state.
2. The active backend keeps execution authority.
3. The voice provider handles duplex speech transport.
4. PersonaPlex is a plausible future self-hosted option for step 3, not a replacement for step 2.

This repo borrows the right ideas from Remodex:

- Codex stays on the Mac
- phone acts as a remote control
- live thread/turn/event streaming
- approvals and interrupts
- bridge owns local environment access

## Repository layout

```text
helm-dev/
├── bridge/
│   ├── package.json
│   ├── tsconfig.json
│   ├── .env.example
│   └── src/
├── ios/
│   ├── project.yml
│   ├── Resources/
│   ├── Sources/
│   └── Tests/
├── macos/
│   ├── project.yml
│   └── Sources/
├── watchos/
│   ├── project.yml
│   └── Sources/
└── scripts/
```

## Quick CLI Bridge Install

For a user-facing install, the supported commands should be:

```bash
npm install -g @devlin/helm
helm setup
```

or:

```bash
brew tap devlin/helm
brew install devlin/helm/helm
helm setup
```

The unscoped names are not available for this project:

- `brew install helm` is already Homebrew's Kubernetes Helm formula.
- `npm install -g helm` is already an unrelated npm package.

For the current unpublished developer path, install from GitHub directly:

```bash
npm install -g github:DEVLlN/helm-dev
helm setup
```

That command:

1. installs the Helm CLI, bridge helpers, runtime shims, shell integration, and binary capture
2. asks you to sign in to Tailscale when this Mac is not already connected to a tailnet
3. starts the bridge and Codex app-server when available, using either the standalone `codex` CLI or the embedded `Codex.app` runtime
4. prints a terminal QR code that the iPhone app can scan for pairing
5. installs hooks so Codex CLI, Claude Code, Grok CLI, and local Ollama model sessions can be discovered by Helm

To pair later, run:

```bash
helm pair
```

`helm pair` starts the bridge first if needed, then prints the QR. When Tailscale is connected, the bridge-authored setup link prefers the Tailscale URL automatically so iPhone pairing works away from your laptop.

Optional runtime support after the same install:

- Grok: install the CLI from `https://grokcli.io/`; Helm detects `grok` or `grok-cli`
- Gemma 4: install Ollama; Helm exposes `helm-gemma` and the mobile Gemma backend, using `HELM_GEMMA_MODEL` when your local tag is not `gemma4`
- Qwen3.5: install Ollama; Helm exposes `helm-qwen` and the mobile Qwen backend, using `HELM_QWEN_MODEL` when your local tag is not `qwen3.5`

If you want a local-network-only setup without Tailscale or a QR during install, use:

```bash
helm setup --skip-tailscale --no-pairing-qr
```

After install, you can restart the bridge and print pairing again:

```bash
helm bridge up --lan
helm bridge pair
```

The installer links these helpers into `~/.local/bin`:

- `helm`
- `helm-install`
- `helm-platforms`
- `helm-prototype-up`
- `helm-prototype-status`
- `helm-prototype-down`
- `helm-pairing-qr`
- `helm-codex`
- `helm-claude`
- `helm-grok`
- `helm-gemma`
- `helm-qwen`

The full macOS app installer still exists for later testing, but it is not the recommended path while the Mac app is unfinished. Use `helm setup --mac-app` only when you explicitly want to build and install the local Mac app from source.

To inspect what Helm can use on the current machine before or after setup, run:

```bash
helm platforms
helm platforms --json
```

Release and tap details live in [Distribution](docs/DISTRIBUTION.md).

If you want to test that installer against a disposable fake user home instead of your real shell config, use:

```bash
scripts/test-install-sandbox.sh
```

For a pass/fail clean-room smoke run that also tears itself down afterward, use:

```bash
scripts/test-install-sandbox.sh --smoke --cleanup
```

That sandbox harness redirects `HOME`, skips launchd PATH mutation and absolute binary capture, installs the Mac app outside `/Applications`, and can start an isolated local bridge plus Codex app-server on temporary ports. `--smoke` asserts the helper commands, runtime shims, shell integration, optional Mac app install, interactive shell resolution, bridge health, and pairing file before exiting.

After a non-cleanup run, the latest sandbox is also available through stable repo-local links:

```bash
source /Users/devlin/GitHub/helm-dev/.runtime/test-install-sandbox/latest-env.sh
/Users/devlin/GitHub/helm-dev/.runtime/test-install-sandbox/latest-run.sh scripts/prototype-status.sh
```

## Bridge setup

Requirements:

- Node.js 20+
- either `codex` on your `PATH` or `Codex.app` installed in `/Applications` or `~/Applications`
- optional `grok` or `grok-cli` on your `PATH` for Grok sessions
- optional `ollama` on your `PATH` for local Gemma/Qwen sessions
- an app-server instance, for example:

```bash
codex app-server --listen ws://127.0.0.1:6060
```

Bridge env:

```bash
cd bridge
cp .env.example .env
npm install
npm run dev
```

Important environment variables:

- `BRIDGE_HOST`
- `BRIDGE_PORT`
- `BRIDGE_PREFERRED_URL`
- `CODEX_APP_SERVER_URL`
- `BRIDGE_PAIRING_FILE`
- `BRIDGE_PAIRING_TOKEN`
- `OPENAI_API_KEY`
- `OPENAI_REALTIME_MODEL`
- `OPENAI_REALTIME_VOICE`
- `VOICE_CONFIRMATION_INSTRUCTIONS`
- `HELM_GEMMA_MODEL`
- `HELM_QWEN_MODEL`

The bridge will generate a pairing token file on first launch if `BRIDGE_PAIRING_TOKEN` is not set. Helm clients can read the local pairing file from the same machine, or you can copy the token into the app settings manually for remote clients.

For the current prototype, the iPhone app permits HTTP bridge access so local-network and Tailscale bridge URLs can be tested without forcing HTTPS during early development.

### Local network and Tailscale-style access

For the safest default, the bridge binds to loopback:

```bash
BRIDGE_HOST=127.0.0.1
```

If you want to reach Helm from your phone over your LAN or a private mesh network such as Tailscale, bind the bridge to all interfaces:

```bash
BRIDGE_HOST=0.0.0.0
npm run dev
```

When started this way, the bridge logs reachable `http://<address>:<port>` URLs for each non-loopback interface. Use one of those URLs as the bridge URL in Helm, then pair using the same bearer token.

The bridge now ranks setup addresses automatically:

- prefer `BRIDGE_PREFERRED_URL` when you want to force a specific external hostname or URL
- otherwise prefer a Tailscale-reachable address when one is available
- otherwise prefer a same-LAN IPv4 address
- keep loopback last for local desktop use

Recommended posture:

- keep `codex app-server` on `127.0.0.1`
- expose only the Helm bridge to the network
- use a private network path first
- do not publish the bridge directly to the public internet
- rotate the pairing token if you shared it outside your trusted devices

## Quick prototype

Bring the local Codex app-server and Helm bridge up together with:

```bash
scripts/prototype-up.sh
```

For on-device iPhone testing over your LAN or a private mesh network, bind the bridge beyond loopback:

```bash
scripts/prototype-up.sh --lan
```

Useful follow-ups:

```bash
scripts/prototype-status.sh
scripts/prototype-down.sh
```

The prototype launcher:

- starts `codex app-server` on `ws://127.0.0.1:6060` if it is not already running, resolving Codex from `PATH`, Helm's binary capture, or the embedded runtime inside `Codex.app`
- starts the Helm bridge on `http://127.0.0.1:8787` or the configured host/port
- prints the current pairing token hint, suggested bridge URLs, and `helm://pair` setup link
- writes logs under `.runtime/prototype/logs`

If you want the lower-level CLI-only setup path without the default Mac app install, run:

```bash
scripts/install-helm-cli.sh
helm-enable-shell-integration
```

That lower-level flow prepares the bridge dependencies, links the local prototype helpers into `~/.local/bin`, installs the `helm`, `helm-platforms`, `helm-codex`, `helm-claude`, `helm-grok`, `helm-gemma`, and `helm-qwen` wrappers, and writes the shell snippet that makes new terminal sessions resolve `codex`, `claude`, `grok`, and `grok-cli` through Helm's runtime-aware entry points. For Codex specifically, Helm can also fall back to the embedded CLI inside `Codex.app` when a separate `codex` binary is not installed.

If `OPENAI_API_KEY` is missing, the prototype still supports text control and local session work, but OpenAI Realtime Command and bridge speech will not be available.

The current prototype also exposes bridge voice-provider discovery at `/api/voice/providers`, and the iPhone and Mac settings now let you choose the preferred Live Command voice provider independently from the execution backend.

For PersonaPlex specifically, the bridge now also exposes provider bootstrap metadata at `/api/voice/providers/personaplex/bootstrap`. That endpoint reports whether PersonaPlex is configured and reachable, the native websocket target Helm expects, the required query parameters, the Helm bridge proxy websocket path, and the protocol notes for the PersonaPlex binary session flow. The iPhone and Mac Settings screens surface the same bootstrap payload so the experimental harness can be inspected without leaving Helm.

When PersonaPlex is configured, Helm also exposes a native websocket proxy at `/ws/voice/personaplex`. That proxy validates the Helm pairing token, resolves the active backend and style context, forwards the PersonaPlex query parameters, and then stays wire-transparent for the upstream binary session.

On iPhone, Helm now also has a first PersonaPlex live-input prototype branch in the hidden Command transport. That path uses the bridge proxy together with browser-side Opus capture to stream mic audio into PersonaPlex, then uses the returned text stream as the current spoken-command interpretation path.

Helm now also proxies the PersonaPlex decoder worker and wasm assets through the bridge and loads them inside the hidden iPhone transport, which gives the prototype a real provider-audio playback foundation when PersonaPlex sends audio pages back. Playback is buffered more smoothly than the initial one-shot source scheduling.

There is also now an experimental provider-native spoken-response branch on iPhone: when PersonaPlex is the selected voice provider, Helm can open a short-lived PersonaPlex text session for compact spoken acknowledgements instead of always falling back to Helm speech. That path builds and fits the upstream protocol shape, but it still needs live validation against a configured PersonaPlex server before it should be treated as production-ready duplex behavior.

## iOS setup

The iOS target is defined with XcodeGen in [`ios/project.yml`](/Users/devlin/GitHub/helm-dev/ios/project.yml).

Generate the project locally with:

```bash
brew install xcodegen
cd ios
xcodegen generate
open Helm.xcodeproj
```

## macOS setup

The macOS menu bar target is defined with XcodeGen in [`macos/project.yml`](/Users/devlin/GitHub/helm-dev/macos/project.yml).

Generate the project locally with:

```bash
brew install xcodegen
cd macos
xcodegen generate
open HelmMac.xcodeproj
```

The current Mac alpha includes:

- a menu bar runtime surface
- a dedicated `Helm Command` panel window
- keyboard shortcuts for opening the panel, refreshing sessions, interrupting, taking control, and starting spoken Command capture
- a speech-recognition path for sending spoken Commands directly from the Mac
- optional continuous listening after a spoken Command is sent
- optional standby listening that keeps re-arming desktop Command capture between interactions
- optional wake-forward behavior for approvals and blockers
- optional automatic listening after wake-forward attention events

Current default shortcuts:

- `Option` + `Command` + `Space`: open `Helm Command`
- `Option` + `Command` + `L`: open `Helm Command` and start listening
- `Option` + `Command` + `R`: refresh sessions
- `Option` + `Command` + `.`: interrupt selected session
- `Option` + `Command` + `T`: take control of selected session

## watchOS setup

The watchOS target is defined with XcodeGen in [`watchos/project.yml`](/Users/devlin/GitHub/helm-dev/watchos/project.yml).

Generate the project locally with:

```bash
brew install xcodegen
cd watchos
xcodegen generate
open HelmWatch.xcodeproj
```

## Command engines

The app is designed around two Command engines:

1. `Local Speech`
   Uses Apple speech recognition plus local TTS for the first usable end-to-end loop.

2. `OpenAI Realtime`
   Intended for the full duplex ChatGPT-style speech path. The bridge now exposes a style-aware client-secret endpoint, a unified WebRTC transcription session path for the iPhone app, and a bridge-backed OpenAI speech output path for compact spoken responses. The current iPhone loop now behaves like a single live Command session instead of separate prepare and start stages.

## Future voice providers

Helm should eventually separate the active execution backend from the live voice provider.

Current preferred path:

- execution backend: Codex
- voice provider: OpenAI Realtime

Planned optional path:

- execution backend: preferred backend selected in Helm
- voice provider: PersonaPlex as a self-hosted duplex speech harness

PersonaPlex looks promising because it is designed for real-time duplex speech, role prompting, and voice conditioning. The tradeoff is deployment complexity: it currently requires its own Python or Moshi server flow, Hugging Face license acceptance, and GPU-oriented setup. Helm now has the first bridge-side PersonaPlex adapter for provider probing, native bootstrap metadata, a native websocket proxy path, bridge-proxied decoder assets, and an iPhone live-input plus provider-audio playback prototype branch. Helm also now has an experimental provider-native spoken-response path on iPhone, but that branch still needs live server validation. The remaining gap is full duplex provider-native spoken runtime output on the Apple clients, so PersonaPlex is still an experimental harness layer rather than the default prototype path.

## Near-term build plan

1. Add remote connectivity beyond localhost without introducing brittle public relay complexity too early.
2. Tighten the current duplex behavior on iPhone into a more unified single-session voice loop.
3. Keep pushing the single-system identity so Command never feels detached from the live Codex thread it is driving.
4. Expand the macOS app into a more persistent background Command surface with richer wake behavior and stronger always-there interaction paths.
5. Add richer diff summaries, git actions, photo attachments, and broader onboarding polish.
