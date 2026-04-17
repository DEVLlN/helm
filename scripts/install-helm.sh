#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_NAME=""
TAILSCALE_SETUP=1
PRINT_PAIRING_QR=1
ASSUME_YES="${HELM_INSTALL_ASSUME_YES:-0}"
NO_INPUT="${HELM_INSTALL_NO_INPUT:-0}"
BRIDGE_STATUS="not started"
TAILSCALE_STATUS="not checked"
PAIRING_QR_STATUS="not printed"
TAILSCALE_NEXT_STEP=""

usage() {
  cat <<'EOF'
Usage: scripts/install-helm.sh [--skip-tailscale] [--no-pairing-qr] [--yes] [--no-input] [--shell zsh|bash]

Default install path for the public Helm bridge checkout.

By default this installs:
  1. Helm CLI, bridge helpers, runtime shims, shell integration, and binary capture
  2. guided Tailscale setup for easy remote pairing
  3. a terminal pairing QR after bridge startup

Optional runtimes auto-hooked after install:
  - Grok via grok or grok-cli from https://grokcli.io/
  - Gemma/Qwen local models via Ollama (helm-gemma / helm-qwen)

Options:
  --skip-tailscale   Skip Tailscale setup.
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

open_url() {
  local url="$1"

  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  else
    echo "$url"
  fi
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
    TAILSCALE_NEXT_STEP="Install Tailscale from the browser that just opened, sign in, then run: helm pair"
    echo "[helm] Tailscale is not installed. Opening the download page..."
    open_url "https://tailscale.com/download"
    echo "[helm] Finish the install, sign in, then rerun 'helm pair' to print your QR."
    return
  fi

  local ip
  ip="$(current_tailscale_ip || true)"
  if [[ -n "$ip" ]]; then
    TAILSCALE_STATUS="active at $ip"
    echo "[helm] Tailscale is ready."
    return
  fi

  TAILSCALE_STATUS="installed but not connected"
  TAILSCALE_NEXT_STEP="Finish the Tailscale sign-in flow that just opened, then run: helm pair"
  echo "[helm] Tailscale needs sign-in before Helm can print a remote pairing QR."
  if command -v open >/dev/null 2>&1; then
    open -a Tailscale >/dev/null 2>&1 || true
  fi
  open_url "https://login.tailscale.com/start"
  echo "[helm] Opening Tailscale sign-in..."
  tailscale up >/dev/null 2>&1 || true

  ip="$(wait_for_tailscale_ip 30 || true)"
  if [[ -n "$ip" ]]; then
    TAILSCALE_STATUS="active at $ip"
    TAILSCALE_NEXT_STEP=""
    echo "[helm] Tailscale is ready."
  else
    TAILSCALE_STATUS="not connected"
    echo "[helm] Finish the Tailscale sign-in flow, then rerun 'helm pair'."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-mac-app|--no-open-mac-app)
      # Compatibility no-op: the public repo is bridge-only.
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

echo "[helm] Installing Helm..."
"$ROOT_DIR/scripts/install-helm-cli.sh" >/dev/null

echo "[helm] Setting up your shell..."
SHELL_CMD=("$ROOT_DIR/scripts/install-helm-shell-integration.sh" --skip-cli-install)
if [[ -n "$SHELL_NAME" ]]; then
  SHELL_CMD+=(--shell "$SHELL_NAME")
fi
"${SHELL_CMD[@]}" >/dev/null

configure_tailscale_for_pairing

if [[ "${HELM_INSTALL_SKIP_RUNTIME_START:-0}" == "1" ]]; then
  BRIDGE_STATUS="skipped (HELM_INSTALL_SKIP_RUNTIME_START=1)"
else
  echo "[helm] Starting the bridge..."
  if HELM_PROTOTYPE_COMPACT=1 HELM_PROTOTYPE_SKIP_PAIRING_QR=1 "$ROOT_DIR/scripts/prototype-up.sh" >/dev/null; then
    BRIDGE_STATUS="running"
  else
    BRIDGE_STATUS="not started"
    echo "[helm] Helm installed, but the bridge did not start. Run 'helm pair' after restarting Codex and Claude." >&2
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
    echo "[helm] Could not print the pairing QR. Re-run 'helm pair' after the bridge is reachable." >&2
  fi
fi

PAIRING_NEXT_STEP="In a Helm client, scan the QR printed above. To print it again, run: helm pair"
if [[ "$PAIRING_QR_STATUS" == "skipped" ]]; then
  PAIRING_NEXT_STEP="Print a pairing QR when you are ready: helm pair"
elif [[ "$PAIRING_QR_STATUS" == "not printed (bridge is not running)" ]]; then
  PAIRING_NEXT_STEP="Start the bridge, then print a pairing QR: helm-prototype-up && helm pair"
elif [[ "$PAIRING_QR_STATUS" != "printed" ]]; then
  PAIRING_NEXT_STEP="Print the pairing QR again after the bridge is reachable: helm pair"
fi

cat <<EOF

Helm is ready.

Restart Codex and Claude.
EOF

if [[ -n "$TAILSCALE_NEXT_STEP" ]]; then
  printf '%s\n' "$TAILSCALE_NEXT_STEP"
elif [[ "$PAIRING_QR_STATUS" != "printed" ]]; then
  printf '%s\n' "$PAIRING_NEXT_STEP"
fi
