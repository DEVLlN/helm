#!/usr/bin/env bash
set -euo pipefail

SELF_NAME="$(basename "$0")"
SCRIPT_PATH="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
HOME_DIR="${HOME:-$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')}"
DEFAULT_BRIDGE_URL="${HELM_BRIDGE_URL:-http://127.0.0.1:8787}"
LAUNCH_REGISTRY_DIR="${HOME_DIR}/.config/helm/runtime-launches"
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

if [[ "$SELF_NAME" == "helm-local-model-wrapper.sh" ]]; then
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'EOF'
Usage:
  helm-gemma [--model MODEL] [ollama run args...]
  helm-qwen [--model MODEL] [ollama run args...]

This script is intended to be called through helm-gemma or helm-qwen.
EOF
    exit 0
  fi

  echo "[helm] Use helm-gemma or helm-qwen (installed by scripts/install-helm-cli.sh)." >&2
  exit 1
fi
case "$SELF_NAME" in
  helm-gemma|helm-local-gemma)
    RUNTIME_ID="local-gemma-4"
    DEFAULT_MODEL="${HELM_GEMMA_MODEL:-gemma4}"
    ;;
  helm-qwen|helm-local-qwen)
    RUNTIME_ID="local-qwen-3.5"
    DEFAULT_MODEL="${HELM_QWEN_MODEL:-qwen3.5}"
    ;;
  *)
    echo "[helm] Unknown local model wrapper invocation: $SELF_NAME" >&2
    exit 1
    ;;
esac

usage() {
  cat <<EOF
Usage: $SELF_NAME [--model MODEL] [ollama run arguments...]

Starts an Ollama model under helm's runtime relay so mobile sessions can discover
and interact with the same local-model terminal process.
EOF
}

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

  echo "[helm] Starting bridge for local model session discovery..." >&2
  if ! helm-prototype-up "${PROTOTYPE_ARGS[@]}" >&2; then
    echo "[helm] Bridge startup failed. Continuing with Ollama." >&2
  fi
}

MODEL="$DEFAULT_MODEL"
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

if [[ $# -gt 1 && "$1" == "--model" ]]; then
  MODEL="$2"
  shift 2
fi

if ! command -v ollama >/dev/null 2>&1; then
  echo "[helm] Missing runtime: ollama" >&2
  echo "[helm] Install Ollama and pull model '$MODEL', then rerun $SELF_NAME." >&2
  exit 1
fi

ensure_bridge_running

exec python3 "$ROOT_DIR/scripts/helm_runtime_relay.py" \
  --registry-dir "$LAUNCH_REGISTRY_DIR" \
  --runtime "$RUNTIME_ID" \
  --wrapper "$SELF_NAME" \
  --cwd "$PWD" \
  -- ollama run "$MODEL" "$@"
