#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
SHIM_DIR="${HOME}/.local/share/helm/runtime-shims"
CONFIG_DIR="${HOME}/.config/helm/shell"
OUTPUT_FORMAT="human"

usage() {
  cat <<'EOF'
Usage: scripts/detect-helm-platforms.sh [--json]

Detect local runtimes and setup support that Helm can use on this machine.

Options:
  --json  Print machine-readable JSON instead of the default text summary.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_FORMAT="json"
      shift
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

resolve_runtime_binary() {
  python3 - "$1" "$SHIM_DIR" "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$ROOT_DIR/scripts/helm-runtime-wrapper.sh" "${PATH:-}" <<'PY'
import os
import sys

runtime_name, shim_dir, shim_script, wrapper_script, path_value = sys.argv[1:]

managed_targets = set()
for candidate in (shim_script, wrapper_script):
    try:
        managed_targets.add(os.path.realpath(candidate))
    except OSError:
        continue

shim_dir = os.path.normpath(shim_dir)

for entry in path_value.split(":"):
    if not entry:
        continue
    if os.path.normpath(entry) == shim_dir:
        continue

    candidate = os.path.join(entry, runtime_name)
    try:
        if not (os.path.exists(candidate) and os.access(candidate, os.X_OK)):
            continue
        resolved = os.path.realpath(candidate)
    except OSError:
        continue

    if resolved in managed_targets:
        continue

    print(candidate)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

resolve_codex_app_binary() {
  local candidate
  for candidate in \
    "/Applications/Codex.app/Contents/Resources/codex" \
    "${HOME}/Applications/Codex.app/Contents/Resources/codex" \
    "/Applications/Codex.app/Contents/MacOS/Codex" \
    "${HOME}/Applications/Codex.app/Contents/MacOS/Codex"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

command_summary() {
  local path="$1"
  if [[ -n "$path" ]]; then
    printf 'available (%s)\n' "$path"
  else
    printf 'missing\n'
  fi
}

OS_ID="$(uname -s 2>/dev/null || echo "unknown")"
case "$OS_ID" in
  Darwin)
    OS_LABEL="macOS"
    ;;
  Linux)
    OS_LABEL="Linux"
    ;;
  *)
    OS_LABEL="$OS_ID"
    ;;
esac

SHELL_NAME="$(basename "${SHELL:-unknown}")"
HELM_CLI_STATUS="not installed (${BIN_DIR}/helm)"
if [[ -x "${BIN_DIR}/helm" ]]; then
  HELM_CLI_STATUS="installed (${BIN_DIR}/helm)"
fi

RUNTIME_SHIMS_STATUS="not installed"
if [[ -x "${SHIM_DIR}/codex" && -x "${SHIM_DIR}/claude" && -x "${SHIM_DIR}/grok" && -x "${SHIM_DIR}/grok-cli" ]]; then
  RUNTIME_SHIMS_STATUS="installed (${SHIM_DIR})"
fi

case "$SHELL_NAME" in
  zsh)
    SHELL_SNIPPET_PATH="${CONFIG_DIR}/integration.zsh"
    ;;
  bash)
    SHELL_SNIPPET_PATH="${CONFIG_DIR}/integration.bash"
    ;;
  *)
    SHELL_SNIPPET_PATH=""
    ;;
esac

if [[ -n "$SHELL_SNIPPET_PATH" && -f "$SHELL_SNIPPET_PATH" ]]; then
  SHELL_INTEGRATION_STATUS="installed (${SHELL_SNIPPET_PATH})"
elif [[ -n "$SHELL_SNIPPET_PATH" ]]; then
  SHELL_INTEGRATION_STATUS="not installed (${SHELL_SNIPPET_PATH})"
else
  SHELL_INTEGRATION_STATUS="unsupported shell (${SHELL_NAME})"
fi

NODE_PATH="$(command -v node || true)"
NPM_PATH="$(command -v npm || true)"
CODEX_CLI_PATH="$(resolve_runtime_binary codex || true)"
CODEX_APP_PATH="$(resolve_codex_app_binary || true)"
CLAUDE_PATH="$(resolve_runtime_binary claude || true)"
GROK_PATH="$(resolve_runtime_binary grok || true)"
if [[ -z "$GROK_PATH" ]]; then
  GROK_PATH="$(resolve_runtime_binary grok-cli || true)"
fi
OLLAMA_PATH="$(resolve_runtime_binary ollama || true)"

NODE_STATUS="$(command_summary "$NODE_PATH")"
NPM_STATUS="$(command_summary "$NPM_PATH")"
CODEX_CLI_STATUS="$(command_summary "$CODEX_CLI_PATH")"
CODEX_APP_STATUS="$(command_summary "$CODEX_APP_PATH")"
CLAUDE_STATUS="$(command_summary "$CLAUDE_PATH")"
GROK_STATUS="$(command_summary "$GROK_PATH")"
OLLAMA_STATUS="$(command_summary "$OLLAMA_PATH")"

GEMMA_STATUS="unavailable (ollama missing)"
QWEN_STATUS="unavailable (ollama missing)"
if [[ -n "$OLLAMA_PATH" ]]; then
  GEMMA_MODEL="${HELM_GEMMA_MODEL:-gemma4}"
  QWEN_MODEL="${HELM_QWEN_MODEL:-qwen3.5}"
  OLLAMA_MODELS="$("$OLLAMA_PATH" list 2>/dev/null | awk 'NR>1 {print $1}' || true)"

  has_ollama_model() {
    local model="$1"
    local model_name
    while IFS= read -r model_name; do
      if [[ -z "$model_name" ]]; then
        continue
      fi
      if [[ "$model_name" == "$model" || "${model_name%%:*}" == "$model" ]]; then
        return 0
      fi
    done <<<"$OLLAMA_MODELS"
    return 1
  }

  if has_ollama_model "$GEMMA_MODEL"; then
    GEMMA_STATUS="ready (${GEMMA_MODEL})"
  else
    GEMMA_STATUS="missing model (${GEMMA_MODEL})"
  fi

  if has_ollama_model "$QWEN_MODEL"; then
    QWEN_STATUS="ready (${QWEN_MODEL})"
  else
    QWEN_STATUS="missing model (${QWEN_MODEL})"
  fi
fi

if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TAILSCALE_IP" ]]; then
    TAILSCALE_STATUS="active (${TAILSCALE_IP})"
  else
    TAILSCALE_STATUS="installed but not connected"
  fi
else
  TAILSCALE_STATUS="missing"
fi

if [[ "$OS_ID" == "Darwin" && -d "$ROOT_DIR/macos/HelmMac.xcodeproj" ]]; then
  MISSING_MAC_APP_TOOLS=()
  for tool in xcodebuild open ditto; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      MISSING_MAC_APP_TOOLS+=("$tool")
    fi
  done

  if [[ ${#MISSING_MAC_APP_TOOLS[@]} -eq 0 ]]; then
    MAC_APP_BUILD_STATUS="available"
  else
    MAC_APP_BUILD_STATUS="unavailable (missing: ${MISSING_MAC_APP_TOOLS[*]})"
  fi
else
  MAC_APP_BUILD_STATUS="unsupported on ${OS_LABEL}"
fi

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  export HELM_DETECT_OS_LABEL="$OS_LABEL"
  export HELM_DETECT_SHELL_NAME="$SHELL_NAME"
  export HELM_DETECT_HELM_CLI_STATUS="$HELM_CLI_STATUS"
  export HELM_DETECT_RUNTIME_SHIMS_STATUS="$RUNTIME_SHIMS_STATUS"
  export HELM_DETECT_SHELL_INTEGRATION_STATUS="$SHELL_INTEGRATION_STATUS"
  export HELM_DETECT_NODE_STATUS="$NODE_STATUS"
  export HELM_DETECT_NPM_STATUS="$NPM_STATUS"
  export HELM_DETECT_CODEX_CLI_STATUS="$CODEX_CLI_STATUS"
  export HELM_DETECT_CODEX_APP_STATUS="$CODEX_APP_STATUS"
  export HELM_DETECT_CLAUDE_STATUS="$CLAUDE_STATUS"
  export HELM_DETECT_GROK_STATUS="$GROK_STATUS"
  export HELM_DETECT_OLLAMA_STATUS="$OLLAMA_STATUS"
  export HELM_DETECT_GEMMA_STATUS="$GEMMA_STATUS"
  export HELM_DETECT_QWEN_STATUS="$QWEN_STATUS"
  export HELM_DETECT_TAILSCALE_STATUS="$TAILSCALE_STATUS"
  export HELM_DETECT_MAC_APP_BUILD_STATUS="$MAC_APP_BUILD_STATUS"

  python3 - <<'PY'
import json
import os

payload = {
    "os": os.environ["HELM_DETECT_OS_LABEL"],
    "shell": os.environ["HELM_DETECT_SHELL_NAME"],
    "helmCLI": os.environ["HELM_DETECT_HELM_CLI_STATUS"],
    "runtimeShims": os.environ["HELM_DETECT_RUNTIME_SHIMS_STATUS"],
    "shellIntegration": os.environ["HELM_DETECT_SHELL_INTEGRATION_STATUS"],
    "node": os.environ["HELM_DETECT_NODE_STATUS"],
    "npm": os.environ["HELM_DETECT_NPM_STATUS"],
    "codexCLI": os.environ["HELM_DETECT_CODEX_CLI_STATUS"],
    "codexApp": os.environ["HELM_DETECT_CODEX_APP_STATUS"],
    "claude": os.environ["HELM_DETECT_CLAUDE_STATUS"],
    "grok": os.environ["HELM_DETECT_GROK_STATUS"],
    "ollama": os.environ["HELM_DETECT_OLLAMA_STATUS"],
    "gemmaModel": os.environ["HELM_DETECT_GEMMA_STATUS"],
    "qwenModel": os.environ["HELM_DETECT_QWEN_STATUS"],
    "tailscale": os.environ["HELM_DETECT_TAILSCALE_STATUS"],
    "macAppBuild": os.environ["HELM_DETECT_MAC_APP_BUILD_STATUS"],
}

print(json.dumps(payload, indent=2))
PY
  exit 0
fi

cat <<EOF
os: ${OS_LABEL}
shell: ${SHELL_NAME}
helm CLI: ${HELM_CLI_STATUS}
runtime shims: ${RUNTIME_SHIMS_STATUS}
shell integration: ${SHELL_INTEGRATION_STATUS}
node: ${NODE_STATUS}
npm: ${NPM_STATUS}
codex CLI: ${CODEX_CLI_STATUS}
Codex.app: ${CODEX_APP_STATUS}
claude: ${CLAUDE_STATUS}
grok: ${GROK_STATUS}
ollama: ${OLLAMA_STATUS}
gemma model: ${GEMMA_STATUS}
qwen model: ${QWEN_STATUS}
tailscale: ${TAILSCALE_STATUS}
macOS app build: ${MAC_APP_BUILD_STATUS}
EOF
