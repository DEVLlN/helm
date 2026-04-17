#!/usr/bin/env bash
set -euo pipefail

SELF_NAME="$(basename "$0")"
SCRIPT_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
HOME_DIR="${HOME:-$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')}"
BIN_DIR="${HOME_DIR}/.local/bin"

export HOME="$HOME_DIR"

export HELM_RUNTIME_SHIM_DIR="${HELM_RUNTIME_SHIM_DIR:-${HOME_DIR}/.local/share/helm/runtime-shims}"

resolve_real_codex() {
  if [[ -n "${HELM_REAL_CODEX_PATH:-}" && -x "${HELM_REAL_CODEX_PATH}" ]]; then
    printf '%s\n' "${HELM_REAL_CODEX_PATH}"
    return 0
  fi

  local capture_file="${HOME_DIR}/.config/helm/runtime-binary-capture.json"
  if [[ -f "$capture_file" ]]; then
    local captured
    captured="$(python3 - <<'PY2' "$capture_file"
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
    real = ((data.get('codex') or {}).get('realPath'))
    if isinstance(real, str) and real:
        print(real)
except Exception:
    pass
PY2
)"
    if [[ -n "$captured" && -x "$captured" ]]; then
      printf '%s\n' "$captured"
      return 0
    fi
  fi

  local candidate
  for candidate in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "${HOME_DIR}/Applications/Codex.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/MacOS/Codex" \
    "${HOME_DIR}/Applications/Codex.app/Contents/MacOS/Codex"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

argv_requests_apply_patch() {
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--codex-run-as-apply-patch" ]]; then
      return 0
    fi
  done

  return 1
}

case "$SELF_NAME" in
  codex)
    if argv_requests_apply_patch "$@"; then
      if REAL_CODEX_PATH="$(resolve_real_codex)"; then
        exec -a "$SELF_NAME" "$REAL_CODEX_PATH" "$@"
      fi
      echo "[helm] Could not resolve real Codex binary for $SELF_NAME" >&2
      exit 1
    fi
    exec "$BIN_DIR/helm-codex" "$@"
    ;;
  claude)
    exec "$BIN_DIR/helm-claude" "$@"
    ;;
  grok|grok-cli)
    exec "$BIN_DIR/helm-grok" "$@"
    ;;
  apply_patch|applypatch)
    if REAL_CODEX_PATH="$(resolve_real_codex)"; then
      exec -a "$SELF_NAME" "$REAL_CODEX_PATH" "$@"
    fi
    echo "[helm] Could not resolve real Codex binary for $SELF_NAME" >&2
    exit 1
    ;;
  *)
    echo "[helm] Unknown runtime shim invocation: $SELF_NAME" >&2
    exit 1
    ;;
esac
