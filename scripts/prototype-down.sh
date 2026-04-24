#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/prototype}"
BRIDGE_DIR="$ROOT_DIR/bridge"

if [[ -f "$BRIDGE_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BRIDGE_DIR/.env"
  set +a
fi

: "${CODEX_APP_SERVER_SOCKET:=$RUNTIME_DIR/codex-app-server.sock}"
LEGACY_CODEX_APP_SERVER_URL="ws://127.0.0.1:6060"
if [[ -z "${CODEX_APP_SERVER_URL:-}" ]] || {
  [[ "${CODEX_APP_SERVER_URL:-}" == "$LEGACY_CODEX_APP_SERVER_URL" ]] \
    && [[ "${HELM_FORCE_LEGACY_CODEX_TCP:-0}" != "1" ]]
}; then
  CODEX_APP_SERVER_URL="unix://$CODEX_APP_SERVER_SOCKET"
fi
export CODEX_APP_SERVER_URL

stop_pid_file() {
  local label="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  local pid
  pid="$(cat "$pid_file")"

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "[prototype] Stopping $label ($pid)"
    kill "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$pid_file"
}

stop_pid_file "helm bridge" "$RUNTIME_DIR/helm-bridge.pid"
stop_pid_file "codex app-server" "$RUNTIME_DIR/codex-app-server.pid"

APP_SERVER_SOCKET_PATH="$(python3 -c 'from urllib.parse import urlparse; import os; parsed=urlparse(os.environ.get("CODEX_APP_SERVER_URL", "")); print(parsed.path or parsed.netloc if parsed.scheme == "unix" else "")')"
if [[ -n "$APP_SERVER_SOCKET_PATH" && "$APP_SERVER_SOCKET_PATH" == "$RUNTIME_DIR/"* ]]; then
  rm -f "$APP_SERVER_SOCKET_PATH"
fi

echo "[prototype] Local helm prototype processes stopped."
