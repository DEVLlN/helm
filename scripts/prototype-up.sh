#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/prototype}"
LOG_DIR="$RUNTIME_DIR/logs"
BRIDGE_DIR="$ROOT_DIR/bridge"
LAN_MODE=0
TAILSCALE_IP=""
TAILSCALE_ACTIVE=0
BRIDGE_HOST_EXPLICIT=0

for arg in "$@"; do
  case "$arg" in
    --lan)
      LAN_MODE=1
      ;;
    *)
      echo "Unsupported argument: $arg" >&2
      echo "Usage: scripts/prototype-up.sh [--lan]" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$LOG_DIR"

if [[ -f "$BRIDGE_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BRIDGE_DIR/.env"
  set +a
fi

if [[ -n "${BRIDGE_HOST:-}" ]]; then
  BRIDGE_HOST_EXPLICIT=1
fi

: "${BRIDGE_HOST:=127.0.0.1}"
: "${BRIDGE_PORT:=8787}"
: "${CODEX_APP_SERVER_URL:=ws://127.0.0.1:6060}"
: "${HELM_RUNTIME_CAPTURE_FILE:=${HOME}/.config/helm/runtime-binary-capture.json}"

if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TAILSCALE_IP" ]]; then
    TAILSCALE_ACTIVE=1
  fi
fi

if [[ "$TAILSCALE_ACTIVE" -eq 1 ]]; then
  if [[ "$BRIDGE_HOST_EXPLICIT" -eq 0 ]] && [[ "$LAN_MODE" -eq 0 ]]; then
    BRIDGE_HOST="0.0.0.0"
  fi

  if [[ -z "${BRIDGE_PREFERRED_URL:-}" ]]; then
    export BRIDGE_PREFERRED_URL="http://${TAILSCALE_IP}:${BRIDGE_PORT}"
  fi
fi

export BRIDGE_HOST BRIDGE_PORT CODEX_APP_SERVER_URL

if [[ "$LAN_MODE" -eq 1 ]]; then
  export BRIDGE_HOST="0.0.0.0"
fi

LOCAL_BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT}"
APP_SERVER_HOST="$(python3 -c 'from urllib.parse import urlparse; import os; print(urlparse(os.environ["CODEX_APP_SERVER_URL"]).hostname or "127.0.0.1")')"
APP_SERVER_PORT="$(python3 -c 'from urllib.parse import urlparse; import os; parsed=urlparse(os.environ["CODEX_APP_SERVER_URL"]); print(parsed.port or 80)')"

port_open() {
  local host="$1"
  local port="$2"
  python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.5)
try:
    sock.connect((host, port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd node
require_cmd npm
require_cmd python3
require_cmd curl

resolve_real_codex() {
  python3 - "$HELM_RUNTIME_CAPTURE_FILE" "${HELM_REAL_CODEX_PATH:-}" "${PATH:-}" <<'PY'
import json
import os
import sys

capture_file, explicit_path, path_value = sys.argv[1:]
home_dir = os.path.expanduser("~")
ignored = set()
for candidate in (
    os.path.join(home_dir, ".local", "share", "helm", "runtime-shims", "codex"),
    os.path.join(home_dir, ".local", "bin", "helm-codex"),
):
    try:
        ignored.add(os.path.realpath(candidate))
    except OSError:
        continue


def usable(candidate):
    if not candidate:
        return False
    try:
        return os.path.exists(candidate) and os.access(candidate, os.X_OK) and os.path.realpath(candidate) not in ignored
    except OSError:
        return False


def codex_app_candidates():
    app_roots = (
        "/Applications/Codex.app",
        os.path.join(home_dir, "Applications", "Codex.app"),
    )
    suffixes = (
        os.path.join("Contents", "Resources", "codex"),
        os.path.join("Contents", "MacOS", "Codex"),
    )
    for app_root in app_roots:
        for suffix in suffixes:
            yield os.path.join(app_root, suffix)


if usable(explicit_path):
    print(explicit_path)
    raise SystemExit(0)

if os.path.exists(capture_file):
    try:
        with open(capture_file, "r", encoding="utf-8") as handle:
            capture = json.load(handle)
        captured_path = ((capture.get("codex") or {}).get("realPath"))
        if usable(captured_path):
            print(captured_path)
            raise SystemExit(0)
    except Exception:
        pass

for entry in path_value.split(":"):
    if not entry:
        continue
    if os.path.normpath(entry) == os.path.normpath(os.path.join(home_dir, ".local", "share", "helm", "runtime-shims")):
        continue
    candidate = os.path.join(entry, "codex")
    if usable(candidate):
        print(candidate)
        raise SystemExit(0)

for candidate in codex_app_candidates():
    if usable(candidate):
        print(candidate)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

CODEX_BINARY="$(resolve_real_codex || true)"
if [[ -z "$CODEX_BINARY" ]]; then
  echo "Missing required real Codex runtime" >&2
  exit 1
fi

launch_detached() {
  local pid_file="$1"
  local log_file="$2"
  local workdir="$3"
  shift 3

  python3 - "$pid_file" "$log_file" "$workdir" "$@" <<'PY'
import os
import subprocess
import sys

pid_file, log_file, workdir, *cmd = sys.argv[1:]
with open(log_file, "ab", buffering=0) as log:
    process = subprocess.Popen(
        cmd,
        cwd=workdir,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        start_new_session=True,
    )

with open(pid_file, "w", encoding="utf-8") as handle:
    handle.write(str(process.pid))
PY
}

stop_pid_file() {
  local label="$1"
  local pid_file="$2"

  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "$pid_file")"

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "[prototype] Stopping $label ($pid)"
    kill "$pid" >/dev/null 2>&1 || true
  fi

  rm -f "$pid_file"
}

start_app_server() {
  if port_open "$APP_SERVER_HOST" "$APP_SERVER_PORT"; then
    echo "[prototype] Codex app-server already listening at $CODEX_APP_SERVER_URL"
    return
  fi

  echo "[prototype] Starting codex app-server at $CODEX_APP_SERVER_URL"
  launch_detached \
    "$RUNTIME_DIR/codex-app-server.pid" \
    "$LOG_DIR/codex-app-server.log" \
    "$ROOT_DIR" \
    "$CODEX_BINARY" app-server --listen "$CODEX_APP_SERVER_URL"
}

start_bridge() {
  if curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
    if [[ "$TAILSCALE_ACTIVE" -eq 1 ]] && [[ "$BRIDGE_HOST" == "0.0.0.0" ]]; then
      local tailscale_bridge_url="http://${TAILSCALE_IP}:${BRIDGE_PORT}"
      if curl -sf --connect-timeout 2 "$tailscale_bridge_url/health" >/dev/null 2>&1; then
        echo "[prototype] helm bridge already available at $LOCAL_BRIDGE_URL and $tailscale_bridge_url"
        return
      fi

      if stop_pid_file "helm bridge" "$RUNTIME_DIR/helm-bridge.pid"; then
        for _ in $(seq 1 10); do
          if ! curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
            break
          fi
          sleep 0.2
        done

        if curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
          echo "[prototype] Existing bridge on port ${BRIDGE_PORT} did not stop; cannot restart for Tailscale binding." >&2
          exit 1
        fi
      else
        echo "[prototype] helm bridge is only reachable locally at $LOCAL_BRIDGE_URL." >&2
        echo "[prototype] Stop the existing bridge on port ${BRIDGE_PORT}, then rerun scripts/prototype-up.sh so helm can bind for Tailscale." >&2
        exit 1
      fi
    else
      echo "[prototype] helm bridge already available at $LOCAL_BRIDGE_URL"
      return
    fi
  fi

  if curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
    echo "[prototype] helm bridge already available at $LOCAL_BRIDGE_URL"
    return
  fi

  echo "[prototype] Starting helm bridge at http://${BRIDGE_HOST}:${BRIDGE_PORT}"
  (
    cd "$BRIDGE_DIR"
    npm install >/dev/null
    npm run build >/dev/null
  )
  launch_detached \
    "$RUNTIME_DIR/helm-bridge.pid" \
    "$LOG_DIR/helm-bridge.log" \
    "$BRIDGE_DIR" \
    node dist/index.js
}

wait_for_bridge() {
  local attempts=60
  local delay=1

  for _ in $(seq 1 "$attempts"); do
    if curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
      return
    fi
    sleep "$delay"
  done

  echo "[prototype] helm bridge did not become ready in time." >&2
  echo "[prototype] Bridge log: $LOG_DIR/helm-bridge.log" >&2
  exit 1
}

start_app_server
start_bridge
wait_for_bridge

PAIRING_JSON="$(curl -sf "$LOCAL_BRIDGE_URL/api/pairing")"
HEALTH_JSON="$(curl -sf "$LOCAL_BRIDGE_URL/health")"

python3 - "$PAIRING_JSON" "$HEALTH_JSON" "$CODEX_APP_SERVER_URL" "$LOCAL_BRIDGE_URL" "$LOG_DIR" <<'PY'
import json
import sys

pairing = json.loads(sys.argv[1])["pairing"]
health = json.loads(sys.argv[2])
app_server_url = sys.argv[3]
local_bridge_url = sys.argv[4]
log_dir = sys.argv[5]

print()
print("helm prototype is up.")
print()
print(f"Local bridge: {local_bridge_url}")
print(f"Codex app-server: {app_server_url}")
print(f"Default backend: {health.get('defaultBackendId', 'unknown')}")
print(f"Pairing token hint: {pairing.get('tokenHint', 'unknown')}")

suggested = pairing.get("suggestedBridgeURLs") or []
if suggested:
    print("Suggested bridge URLs:")
    for url in suggested:
        print(f"  - {url}")

setup_url = pairing.get("setupURL")
if setup_url:
print(f"Setup link: {setup_url}")

print(f"Logs: {log_dir}")
print()
print("Next steps:")
print("  1. Use helm bridge pair to reprint the QR or setup link.")
print("  2. Use scripts/prototype-status.sh to reprint pairing and health info.")
print("  3. Start Codex, Claude, Grok, or local Ollama sessions through Helm.")
print("  4. Use scripts/prototype-down.sh when you want to stop the local stack.")
PY

if [[ "$TAILSCALE_ACTIVE" -eq 1 ]]; then
  echo
  echo "[prototype] Tailscale detected. helm is preferring the Tailscale bridge URL by default:"
  echo "[prototype]   http://${TAILSCALE_IP}:${BRIDGE_PORT}"
fi

if [[ "${HELM_PROTOTYPE_SKIP_PAIRING_QR:-0}" != "1" && -t 1 ]] && [[ "$LAN_MODE" -eq 1 || "$TAILSCALE_ACTIVE" -eq 1 ]]; then
  "$ROOT_DIR/scripts/print-pairing-qr.sh"
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo
  echo "[prototype] OPENAI_API_KEY is not set. Text control will work, but OpenAI Realtime Command and bridge speech will not."
fi
