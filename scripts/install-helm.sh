#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_MAC_APP=1
OPEN_MAC_APP=1
SHELL_NAME=""
TAILSCALE_SETUP=1
PRINT_PAIRING_QR=1
ASSUME_YES="${HELM_INSTALL_ASSUME_YES:-0}"
NO_INPUT="${HELM_INSTALL_NO_INPUT:-0}"
MAC_APP_STATUS="not requested"
BRIDGE_STATUS="not started"
TAILSCALE_STATUS="not checked"
PAIRING_QR_STATUS="not printed"

usage() {
  cat <<'EOF'
Usage: scripts/install-helm.sh [--no-mac-app] [--no-open-mac-app] [--skip-tailscale] [--no-pairing-qr] [--yes] [--no-input] [--shell zsh|bash]

Default install path for Helm on a local Mac checkout.

By default this installs:
  1. Helm CLI, bridge helpers, runtime shims, shell integration, and binary capture
  2. the macOS Helm app for local Command support
  3. an interactive Tailscale sign-in prompt for easy iPhone pairing
  4. a terminal pairing QR for the iPhone app

Optional runtimes auto-hooked after install:
  - Grok via grok or grok-cli from https://grokcli.io/
  - Gemma/Qwen local models via Ollama (helm-gemma / helm-qwen)

Options:
  --no-mac-app       Skip building and installing the macOS helm app.
  --no-open-mac-app  Install the macOS helm app without opening it.
  --skip-tailscale   Skip the Tailscale sign-in prompt.
  --no-pairing-qr    Do not print the terminal pairing QR after bridge startup.
  --yes              Accept Helm's setup prompts automatically when a prompt is offered.
  --no-input         Disable setup prompts even in an interactive terminal.
  --shell SHELL      Force shell integration for zsh or bash.
EOF
}

has_interactive_terminal() {
  [[ -t 0 && -t 1 ]]
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-yes}"
  local suffix="[Y/n]"
  local reply

  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi

  if [[ "$NO_INPUT" == "1" ]]; then
    return 1
  fi

  if ! has_interactive_terminal; then
    return 1
  fi

  if [[ "$default_answer" == "no" ]]; then
    suffix="[y/N]"
  fi

  read -r -p "$prompt $suffix " reply
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$reply" ]]; then
    [[ "$default_answer" == "yes" ]]
    return
  fi

  [[ "$reply" == "y" || "$reply" == "yes" ]]
}

current_tailscale_ip() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 1
  fi

  tailscale ip -4 2>/dev/null | head -n 1
}

wait_for_tailscale_ip() {
  local attempts="${1:-30}"
  local ip

  for _ in $(seq 1 "$attempts"); do
    ip="$(current_tailscale_ip || true)"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
    sleep 2
  done

  return 1
}

configure_tailscale_for_pairing() {
  if [[ "$TAILSCALE_SETUP" -eq 0 || "${HELM_INSTALL_SKIP_TAILSCALE:-0}" == "1" ]]; then
    TAILSCALE_STATUS="skipped"
    return
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    TAILSCALE_STATUS="not installed"
    echo "[helm] Tailscale is the easiest way to pair your iPhone when you are away from this Mac."
    if prompt_yes_no "[helm] Tailscale is not installed. Open the download page now?" "yes"; then
      if command -v open >/dev/null 2>&1; then
        open "https://tailscale.com/download"
      else
        echo "[helm] Download Tailscale: https://tailscale.com/download"
      fi
    else
      echo "[helm] Skipping Tailscale setup. Pairing may only work on local networks until Tailscale is connected."
    fi
    return
  fi

  local ip
  ip="$(current_tailscale_ip || true)"
  if [[ -n "$ip" ]]; then
    TAILSCALE_STATUS="active at $ip"
    echo "[helm] Tailscale is connected at $ip."
    return
  fi

  TAILSCALE_STATUS="installed but not connected"
  echo "[helm] Tailscale is installed but this Mac is not signed in to a tailnet."

  if ! prompt_yes_no "[helm] Sign in to Tailscale now so your iPhone can pair over your tailnet?" "yes"; then
    echo "[helm] Skipping Tailscale sign-in. You can run 'tailscale up' later, then rerun 'helm-pairing-qr'."
    return
  fi

  echo "[helm] Starting Tailscale sign-in. Finish the browser/app login if prompted..."
  if ! tailscale up; then
    echo "[helm] 'tailscale up' did not complete. If you use the macOS Tailscale app, sign in there and rerun helm-install." >&2
    if command -v open >/dev/null 2>&1; then
      open -a Tailscale >/dev/null 2>&1 || true
    fi
  fi

  ip="$(wait_for_tailscale_ip 30 || true)"
  if [[ -n "$ip" ]]; then
    TAILSCALE_STATUS="active at $ip"
    echo "[helm] Tailscale is connected at $ip."
  else
    TAILSCALE_STATUS="not connected"
    echo "[helm] Tailscale is still not connected. Pairing QR will be easiest after you sign in and rerun 'helm-pairing-qr'." >&2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-mac-app)
      INSTALL_MAC_APP=0
      shift
      ;;
    --no-open-mac-app)
      OPEN_MAC_APP=0
      shift
      ;;
    --skip-tailscale)
      TAILSCALE_SETUP=0
      shift
      ;;
    --no-pairing-qr)
      PRINT_PAIRING_QR=0
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --no-input)
      NO_INPUT=1
      shift
      ;;
    --shell)
      SHELL_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "[helm] Installing CLI, bridge helpers, runtime shims, and binary capture..."
"$ROOT_DIR/scripts/install-helm-cli.sh"

echo "[helm] Enabling shell integration..."
SHELL_CMD=("$ROOT_DIR/scripts/install-helm-shell-integration.sh" --skip-cli-install)
if [[ -n "$SHELL_NAME" ]]; then
  SHELL_CMD+=(--shell "$SHELL_NAME")
fi
"${SHELL_CMD[@]}"

if [[ "$INSTALL_MAC_APP" -eq 1 ]]; then
  if command -v xcodebuild >/dev/null 2>&1 && command -v open >/dev/null 2>&1 && command -v ditto >/dev/null 2>&1; then
    MAC_CMD=("$ROOT_DIR/scripts/install-helm-mac-app.sh")
    if [[ "$OPEN_MAC_APP" -eq 0 ]]; then
      MAC_CMD+=(--no-open)
    fi
    if "${MAC_CMD[@]}"; then
      MAC_APP_STATUS="installed"
    else
      MAC_APP_STATUS="install failed"
      echo "[helm] macOS app install failed. helm CLI setup still completed." >&2
    fi
  else
    MAC_APP_STATUS="skipped (Xcode build tools unavailable)"
    echo "[helm] Skipping macOS app install because Xcode build tools are unavailable. Re-run with --no-mac-app to opt out explicitly." >&2
  fi
else
  MAC_APP_STATUS="opted out (--no-mac-app)"
fi

configure_tailscale_for_pairing

DETECTION_SUMMARY="$("$ROOT_DIR/scripts/detect-helm-platforms.sh" || true)"

if [[ "${HELM_INSTALL_SKIP_RUNTIME_START:-0}" == "1" ]]; then
  BRIDGE_STATUS="skipped (HELM_INSTALL_SKIP_RUNTIME_START=1)"
else
  echo "[helm] Starting the local bridge and Codex app-server when available..."
  if HELM_PROTOTYPE_SKIP_PAIRING_QR=1 "$ROOT_DIR/scripts/prototype-up.sh"; then
    BRIDGE_STATUS="running"
  else
    BRIDGE_STATUS="not started"
    echo "[helm] Bridge bring-up did not complete. Helm is installed, but Codex or bridge prerequisites still need attention." >&2
  fi
fi

if [[ "$PRINT_PAIRING_QR" -eq 0 || "${HELM_INSTALL_SKIP_PAIRING_QR:-0}" == "1" ]]; then
  PAIRING_QR_STATUS="skipped"
elif [[ "$BRIDGE_STATUS" != "running" ]]; then
  PAIRING_QR_STATUS="not printed (bridge is not running)"
elif ! has_interactive_terminal; then
  PAIRING_QR_STATUS="not printed (non-interactive terminal)"
else
  if "$ROOT_DIR/scripts/print-pairing-qr.sh"; then
    PAIRING_QR_STATUS="printed"
  else
    PAIRING_QR_STATUS="failed"
    echo "[helm] Could not print the pairing QR. Re-run 'helm-pairing-qr' after the bridge is reachable." >&2
  fi
fi

PAIRING_NEXT_STEP="In iPhone Helm, scan the QR printed above. To print it again, run: helm-pairing-qr"
if [[ "$PAIRING_QR_STATUS" == "skipped" ]]; then
  PAIRING_NEXT_STEP="Print a pairing QR when you are ready: helm-pairing-qr"
elif [[ "$PAIRING_QR_STATUS" == "not printed (bridge is not running)" ]]; then
  PAIRING_NEXT_STEP="Start the bridge, then print a pairing QR: helm-prototype-up && helm-pairing-qr"
elif [[ "$PAIRING_QR_STATUS" != "printed" ]]; then
  PAIRING_NEXT_STEP="Print the pairing QR again after the bridge is reachable: helm-pairing-qr"
fi

cat <<EOF

Helm install is complete.

Installed by default:
  - Helm CLI, bridge helpers, runtime shims, binary capture, and shell integration
  - macOS Helm Command app: $MAC_APP_STATUS

Bridge:
  - $BRIDGE_STATUS
  - tailscale: $TAILSCALE_STATUS
  - pairing QR: $PAIRING_QR_STATUS

Detected local runtimes and setup support:
$(while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$DETECTION_SUMMARY")

Next steps:
  1. Relaunch GUI apps like Codex, Claude, and VS Code so they inherit Helm's runtime capture.
  2. $PAIRING_NEXT_STEP
  3. Start Codex, Claude, Grok, or local Ollama model sessions. Helm will keep those sessions discoverable.
EOF
