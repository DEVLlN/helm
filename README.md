# Helm

Helm sets up the bridge and CLI helpers that keep local Codex sessions reachable from other devices. It handles runtime detection, shell integration, bridge startup, and pairing from one command.

## Install

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

The public npm registry package `@devlin/helm` is still being wired up. Until that is live, use Homebrew or the GitHub install above.

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

## Feature Status

### Completed in the public release

- [x] One-command setup with `helm setup`
- [x] Codex CLI and Codex.app detection
- [x] Claude and Grok runtime wrapping
- [x] Ollama-based `helm-gemma` and `helm-qwen` helpers
- [x] Tailscale-aware pairing and terminal QR output
- [x] Bridge lifecycle commands for `up`, `pair`, `status`, and `down`
- [x] Shell integration and binary capture for GUI-launched tools
- [x] Homebrew install via `devlln/helm`
- [x] GitHub install via `npm install -g github:DEVLlN/helm`

### In progress

- [ ] Public npm registry publish for `@devlin/helm`
- [ ] More first-run validation and repair guidance
- [ ] Broader runtime detection hardening across different local setups

### Planned

- [ ] More runtime and provider wrappers
- [ ] Better pairing diagnostics and recovery commands
- [ ] Additional client integrations built on the bridge API

## Maintainers

Quick validation before tagging a release:

```bash
scripts/check-public-repo.sh
scripts/test-install-sandbox.sh --smoke --cleanup --no-runtime-start
npm run pack:dry-run
```

Release details live in [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md). Test notes live in [TESTING.md](TESTING.md).
