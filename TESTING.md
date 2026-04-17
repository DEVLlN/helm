# helm testing

This file is the current prototype test guide for `helm`.

Use it to validate the local bridge, the Apple clients, and the current `Command` voice paths without having to reconstruct the expected flow from the code.

## Local Prototype

Start the local stack:

```bash
cd /Users/devlin/GitHub/helm-dev
scripts/prototype-up.sh
scripts/prototype-status.sh
```

If Tailscale is active on the Mac, `scripts/prototype-up.sh` now prefers the Tailscale bridge URL automatically and prints a pairing QR directly in the terminal.

Expected local services:

- bridge: `http://127.0.0.1:8787`
- codex app-server: `ws://127.0.0.1:6060`

Stop the local stack:

```bash
scripts/prototype-down.sh
```

## Pairing

Use the pairing QR shown by helm on Mac first. If you need the fallback setup link, print it with:

```bash
scripts/prototype-status.sh
helm-pairing-qr
```

Expected result:

- `helm` scans the pairing QR or imports the `helm://pair` link
- the setup link uses a concrete reachable bridge address rather than `0.0.0.0`
- Tailscale is preferred ahead of LAN addresses when it is available on the host
- the iPhone app is allowed to reach the bridge over plain HTTP during prototype testing
- bridge URL is set automatically
- pairing token is stored
- sessions load without manual token entry

## Installer Sandbox

To simulate a fresh local user install without touching your real `~/.zshrc`, `~/.local/bin`, or helm state, run:

```bash
scripts/test-install-sandbox.sh
```

For an assertion-driven smoke pass that also removes the temp sandbox afterward, run:

```bash
scripts/test-install-sandbox.sh --smoke --cleanup
```

Expected result:

- a temporary sandbox root is created
- helm install runs with a temp `HOME`
- launchd PATH mutation is skipped
- absolute binary capture is skipped
- the Mac app is installed into the sandbox instead of `/Applications`
- the bridge and Codex app-server can start on isolated localhost ports
- `--smoke` verifies helper installs, runtime shims, shell integration, interactive shell resolution, bridge health, and pairing output
- `--cleanup` stops the isolated runtime and removes the sandbox root on exit
- the non-cleanup path still prints a reusable `sandbox-env.sh` and `sandbox-run.sh` for follow-up checks
- the latest non-cleanup sandbox is also exposed through stable repo-local links under `.runtime/test-install-sandbox/`

Useful follow-up commands:

```bash
source /Users/devlin/GitHub/helm-dev/.runtime/test-install-sandbox/latest-env.sh
/Users/devlin/GitHub/helm-dev/.runtime/test-install-sandbox/latest-run.sh scripts/prototype-status.sh
/Users/devlin/GitHub/helm-dev/.runtime/test-install-sandbox/latest-run.sh zsh -ic 'command -v codex && command -v claude && ls -la ~/.local/bin'
```

## Local CLI Setup and Autoinjection

For the guided one-command setup flow, run:

```bash
helm setup
```

To inspect what Helm auto-detects on the current machine, run:

```bash
helm platforms
helm platforms --json
```

For the lower-level helper-only path, install the local helper commands directly:

```bash
scripts/install-helm-cli.sh
```

Enable shell autoinjection:

```bash
helm-enable-shell-integration
```

Expected result:

- `helm` is installed in `~/.local/bin`
- `helm-platforms` is installed in `~/.local/bin`
- `helm-codex` and `helm-claude` are installed in `~/.local/bin`
- `helm-pairing-qr` is installed in `~/.local/bin`
- the helm shell snippet is written under `~/.config/helm/shell/`
- a new terminal window picks up the wrapper functions so `codex` routes to `helm-codex` and `claude` routes to `helm-claude`
- launching `codex` or `claude` auto-starts the bridge when it is not already running
- if Tailscale is active, the bridge prefers the Tailscale URL automatically without needing `--lan`
- active sessions remain discoverable in helm once the runtime starts
- fresh shell-integrated `codex` sessions expose a local relay socket, so turns sent from iPhone or Mac land in the exact live terminal session instead of only a detached resume fallback
- older CLI sessions that were launched before the shell-relay update must be restarted to gain that live relay path

## iPhone App

Open:

- `/Users/devlin/GitHub/helm-dev/ios/Helm.xcodeproj`

Build target:

- `helm`

Recommended simulator:

- `iPhone 17 Pro`

### Baseline App Checks

1. Launch `helm`.
2. Confirm the onboarding or setup card appears on a fresh state.
3. Pair using the setup link or local token.
4. Confirm the Sessions screen loads discoverable Codex threads, including CLI-started sessions that were not created from the phone.

Expected result:

- bridge status is healthy
- sessions list renders
- controller ownership badges appear
- Command tab opens without errors

### iPhone UI Screenshot Capture

Use the repo script:

```bash
scripts/capture-ios-screens.sh
```

Optional output folder:

```bash
scripts/capture-ios-screens.sh /tmp/helm-ui-review
```

Expected result:

- helm rebuilds for the booted iPhone simulator
- the app is installed automatically
- `sessions.png`, `command.png`, and `settings.png` are captured
- screenshots are written to the requested output folder

### Command with OpenAI Realtime

Preconditions:

- `OPENAI_API_KEY` set in `bridge/.env`

Steps:

1. In Settings, select `OpenAI Realtime` as the preferred voice provider.
2. Open `Command`.
3. Start Live Command.
4. Speak a short request such as:
   `Codex, summarize the active repository status.`

Expected result:

- microphone access succeeds
- Live Command enters listening state
- transcript appears
- command is dispatched
- Codex acknowledgement is spoken
- session remains live and returns to listening

### Command with PersonaPlex Selected but Unconfigured

Steps:

1. In Settings, select `PersonaPlex` as the preferred voice provider.
2. Open `Command`.
3. Start Live Command.

Expected result:

- helm surfaces that PersonaPlex is not configured
- the provider bootstrap note remains visible in Settings
- the app does not crash or wedge the Command UI

### Command with PersonaPlex Configured

Preconditions:

- `PERSONAPLEX_BASE_URL` points to a reachable PersonaPlex server
- any required PersonaPlex auth token is configured in `bridge/.env`

Steps:

1. Restart the local bridge.
2. Confirm `scripts/prototype-status.sh` reports PersonaPlex reachable.
3. Select `PersonaPlex` in Settings.
4. Start Live Command.
5. Speak a short request.

Expected current prototype behavior:

- helm opens the PersonaPlex proxy websocket
- mic audio is streamed through the bridge proxy
- text deltas are used as the spoken-command interpretation path
- provider audio pages, if returned, are decoded through the bridge-proxied worker and wasm assets
- compact provider-native spoken responses may play through the experimental short-lived PersonaPlex speech session
- if the provider-native speech branch fails or returns no usable audio, helm falls back to the normal bridge speech path

Current limit:

- this path still needs live validation against a real PersonaPlex server before it should be treated as production-ready duplex behavior

## macOS App

Open:

- `/Users/devlin/GitHub/helm-dev/macos/HelmMac.xcodeproj`

Build target:

- `HelmMac`

Checks:

1. Launch the menu bar app.
2. In Settings, use `Run Full Setup` or the individual CLI setup buttons.
3. Confirm the pairing QR renders after bridge startup.
4. Confirm recent sessions load.
5. Trigger a quick command from the Command panel.
6. Verify alerts appear for approvals, blockers, or completions.

Expected result:

- menu bar state updates
- command panel opens
- CLI setup buttons run without errors and surface useful output
- the pairing QR is available directly from the Mac app once the bridge is up
- quick actions work
- settings show backend and voice-provider details

## Apple Watch

Open:

- `/Users/devlin/GitHub/helm-dev/watchos/HelmWatch.xcodeproj`

Build target:

- `HelmWatch`

Checks:

1. Launch the watch app.
2. Confirm the `Now` surface shows the highest-priority thread.
3. Verify quick approval actions render.
4. Verify Continue on iPhone deep link behavior.

Expected result:

- runtime state updates appear
- quick approval actions work
- iPhone handoff opens the right thread

## Lock Screen and Alerts

iPhone checks:

1. Trigger an approval or blocker from Codex.
2. Background the app or lock the phone.
3. Wait for the alert.

Expected result:

- notification arrives
- `Approve`, `Decline`, and `Open` actions appear when applicable
- best-effort spoken alerts occur when the chosen settings and iOS state allow it

Current limit:

- locked-screen spoken alerts remain best-effort because iOS decides what survives suspension

## Regression Checklist

Run this before calling a prototype cut stable:

1. `scripts/prototype-status.sh` returns healthy bridge status.
2. `helm` builds on iPhone simulator.
3. `HelmMac` builds on macOS.
4. `HelmWatch` builds on watchOS simulator.
5. pairing link import works.
6. OpenAI Realtime Live Command works.
7. PersonaPlex selection does not break the app when unconfigured.
8. notifications still deep-link into the right thread.
9. controller ownership and handoff state remain visible.
