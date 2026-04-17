#!/usr/bin/env bash
set -euo pipefail

SELF_NAME="$(basename "$0")"
SCRIPT_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
HOME_DIR="${HOME:-$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')}"
DEFAULT_BRIDGE_URL="${HELM_BRIDGE_URL:-http://127.0.0.1:8787}"
LAUNCH_REGISTRY_DIR="${HOME_DIR}/.config/helm/runtime-launches"
DEFAULT_SHIM_DIR="${HELM_RUNTIME_SHIM_DIR:-${HOME_DIR}/.local/share/helm/runtime-shims}"
CAPTURE_FILE="${HELM_RUNTIME_CAPTURE_FILE:-${HOME_DIR}/.config/helm/runtime-binary-capture.json}"
PROTOTYPE_ARGS=()

export HOME="$HOME_DIR"

case "${HELM_RUNTIME_WRAPPER_SCOPE:-lan}" in
  lan)
    PROTOTYPE_ARGS+=(--lan)
    ;;
  local)
    ;;
  *)
    ;;
esac

case "$SELF_NAME" in
  helm-codex)
    RUNTIME_COMMAND="codex"
    ;;
  helm-claude)
    RUNTIME_COMMAND="claude"
    ;;
  helm-grok)
    RUNTIME_COMMAND="grok"
    ;;
  *)
    echo "[helm] Unknown wrapper invocation: $SELF_NAME" >&2
    exit 1
    ;;
esac

ensure_bridge_running() {
  if [[ "${HELM_DISABLE_AUTO_BRIDGE:-0}" == "1" ]]; then
    return
  fi

  if curl -sf --max-time 1 "$DEFAULT_BRIDGE_URL/health" >/dev/null 2>&1; then
    return
  fi

  if ! command -v helm-prototype-up >/dev/null 2>&1; then
    return
  fi

  echo "[helm] Starting bridge for ${RUNTIME_COMMAND} session discovery..." >&2
  if ! helm-prototype-up "${PROTOTYPE_ARGS[@]}" >&2; then
    echo "[helm] Bridge startup failed. Continuing with ${RUNTIME_COMMAND}." >&2
  fi
}

resolve_runtime() {
  python3 - "$RUNTIME_COMMAND" "$DEFAULT_SHIM_DIR" "$ROOT_DIR" "$HOME_DIR" "${PATH:-}" "$CAPTURE_FILE" "${HELM_REAL_CODEX_PATH:-}" "${HELM_REAL_CLAUDE_PATH:-}" "${HELM_REAL_GROK_PATH:-}" <<'PY'
import json
import os
import sys

runtime, shim_dir, root_dir, home_dir, path_value, capture_file, explicit_codex, explicit_claude, explicit_grok = sys.argv[1:]
candidate_commands = ["grok", "grok-cli"] if runtime == "grok" else [runtime]

ignored = set()
for candidate in (
    os.path.join(root_dir, "scripts", "helm-runtime-shim.sh"),
    os.path.join(root_dir, "scripts", "helm-runtime-wrapper.sh"),
    os.path.join(home_dir, ".local", "bin", f"helm-{runtime}"),
):
    try:
        ignored.add(os.path.realpath(candidate))
    except OSError:
        continue
for command in candidate_commands:
    for candidate in (os.path.join(shim_dir, command),):
        try:
            ignored.add(os.path.realpath(candidate))
        except OSError:
            continue


def usable(candidate):
    if not candidate:
        return False
    try:
        if not os.path.exists(candidate) or not os.access(candidate, os.X_OK):
            return False
        return os.path.realpath(candidate) not in ignored
    except OSError:
        return False


explicit = {"codex": explicit_codex, "claude": explicit_claude, "grok": explicit_grok}.get(runtime, "")
if usable(explicit):
    print(explicit)
    raise SystemExit(0)


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

if os.path.exists(capture_file):
    try:
        with open(capture_file, "r", encoding="utf-8") as handle:
            capture = json.load(handle)
        captured = ((capture.get(runtime) or {}).get("realPath"))
        if usable(captured):
            print(captured)
            raise SystemExit(0)
    except Exception:
        pass

for entry in path_value.split(":"):
    if not entry:
        continue
    if os.path.normpath(entry) == os.path.normpath(shim_dir):
        continue
    for command in candidate_commands:
        candidate = os.path.join(entry, command)
        if usable(candidate):
            print(candidate)
            raise SystemExit(0)

if runtime == "codex":
    for candidate in codex_app_candidates():
        if usable(candidate):
            print(candidate)
            raise SystemExit(0)

raise SystemExit(1)
PY
}

ensure_bridge_running

export HELM_SHELL_INTEGRATED=1
export HELM_RUNTIME="$RUNTIME_COMMAND"
export HELM_WRAPPER_REPO_ROOT="$ROOT_DIR"

if ! RUNTIME_PATH="$(resolve_runtime)"; then
  echo "[helm] Missing runtime: $RUNTIME_COMMAND" >&2
  exit 1
fi
RUNTIME_CWD="$PWD"
RESUME_TARGET=""
THREAD_ID=""
THREAD_ARG_INDEX="-1"
COMMAND_ARGS=("$RUNTIME_PATH" "$@")

if [[ "$RUNTIME_COMMAND" == "codex" ]]; then
  eval "$(python3 "$ROOT_DIR/scripts/helm_codex_wrapper_plan.py" --cwd "$PWD" -- "$@")"
  RUNTIME_CWD="$HELM_WRAPPER_RUNTIME_CWD"
  RESUME_TARGET="$HELM_WRAPPER_RESUME_TARGET"
  THREAD_ID="$HELM_WRAPPER_THREAD_ID"
  THREAD_ARG_INDEX="$HELM_WRAPPER_THREAD_ARG_INDEX"

  if [[ -n "$RESUME_TARGET" && "${HELM_SKIP_MANAGED_THREAD_REWRITE:-0}" != "1" ]]; then
    if ENSURED_THREAD_ID="$(
      python3 "$ROOT_DIR/scripts/helm_ensure_managed_codex_thread.py" \
        --bridge-url "$DEFAULT_BRIDGE_URL" \
        --thread-target "$RESUME_TARGET" \
        2>&1
    )"; then
      THREAD_ID="$ENSURED_THREAD_ID"
      if [[ "$THREAD_ARG_INDEX" != "-1" ]]; then
        COMMAND_ARGS[$((THREAD_ARG_INDEX + 1))]="$THREAD_ID"
      fi
    else
      echo "[helm] Managed-session replacement failed. Continuing with requested thread." >&2
      echo "[helm] $ENSURED_THREAD_ID" >&2
    fi
  fi

  if [[ "$HELM_WRAPPER_BOOTSTRAP" == "1" ]]; then
    if BOOTSTRAP_THREAD_ID="$(
      python3 "$ROOT_DIR/scripts/helm_bootstrap_codex_thread.py" \
        --bridge-url "$DEFAULT_BRIDGE_URL" \
        --cwd "$RUNTIME_CWD" \
        --model "$HELM_WRAPPER_BOOTSTRAP_MODEL" \
        2>&1
    )"; then
      THREAD_ID="$BOOTSTRAP_THREAD_ID"
      COMMAND_ARGS=("$RUNTIME_PATH" "resume" "$THREAD_ID" "$@")
    else
      echo "[helm] Codex bootstrap failed. Continuing with raw launch." >&2
      echo "[helm] $BOOTSTRAP_THREAD_ID" >&2
    fi
  fi
elif [[ "$RUNTIME_COMMAND" == "claude" ]]; then
  CLAUDE_ARGS=("$@")
  for ((i = 0; i < ${#CLAUDE_ARGS[@]}; i++)); do
    case "${CLAUDE_ARGS[$i]}" in
      --resume=*)
        THREAD_ID="${CLAUDE_ARGS[$i]#--resume=}"
        break
        ;;
      --resume|-r)
        if (( i + 1 < ${#CLAUDE_ARGS[@]} )); then
          THREAD_ID="${CLAUDE_ARGS[$((i + 1))]}"
        fi
        break
        ;;
    esac
  done
fi

RELAY_ARGS=(
  --registry-dir "$LAUNCH_REGISTRY_DIR"
  --runtime "$RUNTIME_COMMAND"
  --wrapper "$SELF_NAME"
  --cwd "$RUNTIME_CWD"
)

if [[ -n "$THREAD_ID" ]]; then
  RELAY_ARGS+=(--thread-id "$THREAD_ID")
fi

exec python3 "$ROOT_DIR/scripts/helm_runtime_relay.py" \
  "${RELAY_ARGS[@]}" \
  -- "${COMMAND_ARGS[@]}"
