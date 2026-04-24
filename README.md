<p align="center">
  <img src="https://raw.githubusercontent.com/DEVLlN/helm/main/docs/brand/helm-icon-v1/helm-app-icon-v1-1024.png" alt="Helm app icon" width="128">
</p>

# Helm

Helm sets up the bridge and CLI helpers that keep local Codex sessions reachable from other devices. It handles runtime detection, shell integration, bridge startup, and pairing from one command.

## Install

### npm

```bash
npm install -g @devlln/helm
helm setup
```

### Homebrew

```bash
brew tap devlln/helm
brew install devlln/helm/helm
helm setup
```

### GitHub install

```bash
npm install -g github:DEVLlN/helm
helm setup
```

## Setup

Run the guided setup:

```bash
helm setup
```

`helm setup` installs the CLI, bridge helpers, runtime shims, shell integration, and binary capture. It also checks local runtimes, can guide Tailscale sign-in, starts the bridge, and prints a pairing QR in the terminal.

Useful setup commands:

```bash
helm setup --skip-tailscale
helm setup --no-pairing-qr
helm platforms
helm platforms --json
```

Helm can detect:

- Codex CLI
- Codex.app with its embedded CLI
- Claude
- Grok
- Ollama for local Gemma and Qwen models
- Tailscale for remote pairing

## Usage

Bridge lifecycle:

```bash
helm bridge up
helm bridge pair
helm bridge status
helm bridge down
```

Runtime helpers:

```bash
helm-codex
helm-claude
helm-grok
helm-gemma
helm-qwen
```

Lower-level helpers:

```bash
helm-prototype-up
helm-prototype-status
helm-prototype-down
helm-bridge-service install
helm-pairing-qr
```

Compatibility aliases:

```bash
helm up
helm pair
helm status
helm down
```

If Tailscale is connected, Helm prefers the Tailscale bridge URL automatically when it prints pairing details.

## Apps Coming Soon

Helm is also being built as native iOS and macOS apps. They are not included in the public install yet, but they are planned as the main user-facing surfaces for the bridge.

### Helm iOS

Coming soon.

Features already working in the development app:

- Pair with the local Helm bridge by QR code, setup link, clipboard import, or manual bridge URL and token
- Prefer Tailscale bridge URLs when available, with setup recovery prompts when pairing or connectivity needs attention
- Browse active, recent, and archived sessions with search, stable ordering, and quick move/archive gestures
- Open, resume, create, and control shared Codex sessions from the phone
- Send follow-up turns, interrupt running work, take or release control, and hand sessions back to the CLI
- Review and respond to approvals, including one-time and session-scoped permission decisions when supported
- Inspect full session output with terminal-style command output, tool activity, file changes, message transcript, and Codex TUI lifecycle rows
- Use a mobile composer with queued sends, camera/photo attachments, file attachments, command history, local file autocomplete, and skill autocomplete
- Use spoken Command with live transcription, target-aware routing, spoken confirmations, and a visible live Command state
- Receive notifications for approvals, blockers, and completions, with deep links back into the right session
- See backend availability and session capabilities for Codex, Codex.app, Claude, Grok, and local Ollama-backed model profiles
- Use setup checklists, diagnostics, and responsiveness health summaries for pairing, snapshots, approvals, reconnects, and launch readiness

Planned before the public iOS release:

- TestFlight distribution and a public beta path
- More first-run setup polish for bridge pairing, Tailscale, notifications, and speech permissions
- Broader real-device performance validation on long-running sessions
- Richer file, artifact, and attachment transfer between the phone and Mac-hosted sessions
- Deeper Codex TUI parity as new tool, lifecycle, and agent-status rows ship
- More resilient background alerts within iOS background-execution limits
- More backend and voice-provider options behind the same Command workflow

### Helm macOS

Coming soon.

Features already working in the development app:

- Menu bar access to the same Helm bridge and shared session state as the CLI and iPhone app
- A Command panel for selecting a session, sending the next turn, interrupting work, and handling approval prompts
- QR and setup-link pairing for the iPhone app, including suggested bridge URLs and Tailscale-preferred routing
- Settings for bridge pairing, backend discovery, voice providers, notifications, speech capture, and local helper installation
- Local helper installation for CLI wrappers, shell integration, bridge startup, and runtime discovery
- Notifications and wake behavior for approvals, blockers, and completions
- Spoken Command capture, standby listening, and keyboard shortcuts for opening Command quickly
- Backend-aware session details and affordances for Codex, Claude, Grok, and local Ollama-backed model profiles
- Visibility into command executions, file changes, selected session state, and current control ownership
- Diagnostics and responsiveness health summaries for launch, snapshots, approvals, reconnects, and command acknowledgement

Planned before the public macOS release:

- A signed and notarized macOS app distribution path
- A simpler installer and updater flow alongside npm and Homebrew
- More launch-at-login and menu bar onboarding polish
- Stronger pairing repair and degraded-network recovery flows
- Richer always-listening desktop Command behavior
- Deeper git, diff, review, and local CLI action surfaces
- Tighter cross-device handoff with iOS, watchOS, and future clients

## Feature Status

### Completed in the public release

- [x] One-command setup with `helm setup`
- [x] Codex CLI and Codex.app detection
- [x] Claude and Grok runtime wrapping
- [x] Ollama-based `helm-gemma` and `helm-qwen` helpers
- [x] Tailscale-aware pairing and terminal QR output
- [x] Bridge lifecycle commands for `up`, `pair`, `status`, and `down`
- [x] Shell integration and binary capture for GUI-launched tools
- [x] Public npm install via `npm install -g @devlln/helm`
- [x] Homebrew install via `devlln/helm`
- [x] GitHub install via `npm install -g github:DEVLlN/helm`

### In progress

- [ ] More first-run validation and repair guidance
- [ ] Broader runtime detection hardening across different local setups
- [ ] Helm iOS app, coming soon
- [ ] Helm macOS app, coming soon

### Planned

- [ ] Public TestFlight and signed app distribution for native clients
- [ ] More runtime and provider wrappers
- [ ] Better pairing diagnostics and recovery commands
- [ ] Additional client integrations built on the bridge API
