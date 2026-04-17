#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/prototype}"

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

echo "[prototype] Local helm prototype processes stopped."
