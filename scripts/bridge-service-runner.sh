#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/launchd}"
LOG_DIR="$RUNTIME_DIR/logs"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
HELM_RUNTIME_CAPTURE_FILE="${HELM_RUNTIME_CAPTURE_FILE:-${HOME}/.config/helm/runtime-binary-capture.json}"

for candidate in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  if [[ -d "$candidate" ]] && [[ ":$PATH:" != *":$candidate:"* ]]; then
    PATH="$candidate:$PATH"
  fi
done
export PATH

if [[ -f "$BRIDGE_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BRIDGE_DIR/.env"
  set +a
fi

: "${BRIDGE_HOST:=0.0.0.0}"
: "${BRIDGE_PORT:=8787}"
: "${CODEX_APP_SERVER_SOCKET:=$RUNTIME_DIR/codex-app-server.sock}"

LEGACY_CODEX_APP_SERVER_URL="ws://127.0.0.1:6060"
if [[ -z "${CODEX_APP_SERVER_URL:-}" ]] || {
  [[ "${CODEX_APP_SERVER_URL:-}" == "$LEGACY_CODEX_APP_SERVER_URL" ]] \
    && [[ "${HELM_FORCE_LEGACY_CODEX_TCP:-0}" != "1" ]]
}; then
  CODEX_APP_SERVER_URL="unix://$CODEX_APP_SERVER_SOCKET"
fi

export BRIDGE_HOST BRIDGE_PORT CODEX_APP_SERVER_URL CODEX_APP_SERVER_SOCKET

if [[ -z "$NODE_BIN" ]]; then
  echo "[bridge-service] node is required to run the helm bridge service" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[bridge-service] Missing required command: $1" >&2
    exit 1
  fi
}

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

unix_socket_open() {
  local socket_path="$1"
  if [[ ! -S "$socket_path" ]]; then
    return 1
  fi

  python3 - "$socket_path" <<'PY'
import socket
import sys

socket_path = sys.argv[1]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(0.5)
try:
    sock.connect(socket_path)
except OSError:
    sys.exit(1)
finally:
    sock.close()
PY
}

APP_SERVER_SCHEME="$(python3 -c 'from urllib.parse import urlparse; import os; print(urlparse(os.environ["CODEX_APP_SERVER_URL"]).scheme)')"
APP_SERVER_SOCKET_PATH=""
APP_SERVER_HOST=""
APP_SERVER_PORT=""
if [[ "$APP_SERVER_SCHEME" == "unix" ]]; then
  APP_SERVER_SOCKET_PATH="$(python3 -c 'from urllib.parse import urlparse; import os; parsed=urlparse(os.environ["CODEX_APP_SERVER_URL"]); print(parsed.path or parsed.netloc)')"
  if [[ -z "$APP_SERVER_SOCKET_PATH" ]]; then
    echo "[bridge-service] CODEX_APP_SERVER_URL uses unix:// but does not include a socket path." >&2
    exit 1
  fi
else
  APP_SERVER_HOST="$(python3 -c 'from urllib.parse import urlparse; import os; print(urlparse(os.environ["CODEX_APP_SERVER_URL"]).hostname or "127.0.0.1")')"
  APP_SERVER_PORT="$(python3 -c 'from urllib.parse import urlparse; import os; parsed=urlparse(os.environ["CODEX_APP_SERVER_URL"]); print(parsed.port or 80)')"
fi

require_cmd python3

CODEX_BINARY="$(resolve_real_codex || true)"
if [[ -z "$CODEX_BINARY" ]]; then
  echo "[bridge-service] Missing required real Codex runtime" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

APP_SERVER_PID=""
BRIDGE_PID=""

cleanup() {
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" >/dev/null 2>&1; then
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$APP_SERVER_PID" ]] && kill -0 "$APP_SERVER_PID" >/dev/null 2>&1; then
    kill "$APP_SERVER_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$BRIDGE_PID" ]]; then
    wait "$BRIDGE_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$APP_SERVER_PID" ]]; then
    wait "$APP_SERVER_PID" >/dev/null 2>&1 || true
  fi
}

trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT

start_app_server_if_needed() {
  if [[ "$APP_SERVER_SCHEME" == "unix" ]]; then
    if unix_socket_open "$APP_SERVER_SOCKET_PATH"; then
      echo "[bridge-service] Codex app-server already listening at $CODEX_APP_SERVER_URL"
      return
    fi

    if [[ -e "$APP_SERVER_SOCKET_PATH" ]]; then
      echo "[bridge-service] Removing stale Codex app-server socket at $APP_SERVER_SOCKET_PATH"
      rm -f "$APP_SERVER_SOCKET_PATH"
    fi

    mkdir -p "$(dirname "$APP_SERVER_SOCKET_PATH")"
  else
    if port_open "$APP_SERVER_HOST" "$APP_SERVER_PORT"; then
      echo "[bridge-service] Codex app-server already listening at $CODEX_APP_SERVER_URL"
      return
    fi
  fi

  echo "[bridge-service] Starting Codex app-server at $CODEX_APP_SERVER_URL"
  "$CODEX_BINARY" app-server --listen "$CODEX_APP_SERVER_URL" &
  APP_SERVER_PID="$!"
}

start_app_server_if_needed

echo "[bridge-service] Starting helm bridge at http://${BRIDGE_HOST}:${BRIDGE_PORT}"
"$NODE_BIN" "$BRIDGE_DIR/dist/index.js" &
BRIDGE_PID="$!"

while kill -0 "$BRIDGE_PID" >/dev/null 2>&1; do
  if [[ -n "$APP_SERVER_PID" ]] && ! kill -0 "$APP_SERVER_PID" >/dev/null 2>&1; then
    echo "[bridge-service] Codex app-server exited; stopping helm bridge for launchd restart" >&2
    kill "$BRIDGE_PID" >/dev/null 2>&1 || true
    wait "$APP_SERVER_PID" >/dev/null 2>&1 || true
    wait "$BRIDGE_PID" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep 1
done

wait "$BRIDGE_PID"
