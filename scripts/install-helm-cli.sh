#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"
BIN_DIR="${HOME}/.local/bin"
SHIM_DIR="${HOME}/.local/share/helm/runtime-shims"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd node
require_cmd npm

mkdir -p "$BIN_DIR"

echo "[helm] Installing bridge dependencies..."
(
  cd "$BRIDGE_DIR"
  npm install
)

link_script() {
  local source_path="$1"
  local target_name="$2"
  ln -sf "$source_path" "$BIN_DIR/$target_name"
}

link_script "$ROOT_DIR/bin/helm.js" "helm"
link_script "$ROOT_DIR/scripts/install-helm.sh" "helm-install"
link_script "$ROOT_DIR/scripts/prototype-up.sh" "helm-prototype-up"
link_script "$ROOT_DIR/scripts/prototype-status.sh" "helm-prototype-status"
link_script "$ROOT_DIR/scripts/prototype-down.sh" "helm-prototype-down"
link_script "$ROOT_DIR/scripts/print-pairing-qr.sh" "helm-pairing-qr"
link_script "$ROOT_DIR/scripts/detect-helm-platforms.sh" "helm-platforms"
link_script "$ROOT_DIR/scripts/install-helm-shell-integration.sh" "helm-enable-shell-integration"
link_script "$ROOT_DIR/scripts/install-helm-runtime-shims.sh" "helm-enable-runtime-shims"
link_script "$ROOT_DIR/scripts/install-helm-binary-capture.sh" "helm-enable-binary-capture"
link_script "$ROOT_DIR/scripts/disable-helm-binary-capture.sh" "helm-disable-binary-capture"
link_script "$ROOT_DIR/scripts/helm-runtime-wrapper.sh" "helm-codex"
link_script "$ROOT_DIR/scripts/helm-runtime-wrapper.sh" "helm-claude"
link_script "$ROOT_DIR/scripts/helm-runtime-wrapper.sh" "helm-grok"
link_script "$ROOT_DIR/scripts/helm-local-model-wrapper.sh" "helm-gemma"
link_script "$ROOT_DIR/scripts/helm-local-model-wrapper.sh" "helm-qwen"
link_script "$ROOT_DIR/scripts/helm-local-model-wrapper.sh" "helm-local-gemma"
link_script "$ROOT_DIR/scripts/helm-local-model-wrapper.sh" "helm-local-qwen"

RUNTIME_SHIM_OUTPUT="$("$ROOT_DIR/scripts/install-helm-runtime-shims.sh")"
BINARY_CAPTURE_OUTPUT="$("$ROOT_DIR/scripts/install-helm-binary-capture.sh")"
DETECTION_SUMMARY="$("$ROOT_DIR/scripts/detect-helm-platforms.sh" || true)"

cat <<EOF

helm local CLI setup is ready.

Installed helper commands in:
  $BIN_DIR

Available helpers:
  helm
  helm-install
  helm-prototype-up
  helm-prototype-status
  helm-prototype-down
  helm-pairing-qr
  helm-platforms
  helm-enable-shell-integration
  helm-enable-runtime-shims
  helm-enable-binary-capture
  helm-disable-binary-capture
  helm-codex
  helm-claude
  helm-grok
  helm-gemma
  helm-qwen
  helm-local-gemma
  helm-local-qwen

Detected local runtimes and setup support:
$(while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$DETECTION_SUMMARY")

Recommended next steps:
  1. Run the guided one-command setup:
     helm setup
  2. Or, if you prefer the lower-level steps, enable shell integration explicitly:
     helm-enable-shell-integration
  3. Relaunch GUI apps like Codex, Claude, Grok, and VS Code so they inherit helm's runtime shim PATH.
  4. Start the bridge for cross-device use:
     helm-prototype-up
  5. Print a pairing QR in the terminal if you need it again:
     helm-pairing-qr
  6. In a Helm client, scan the pairing QR.
  7. Start Codex CLI, Claude Code, or Grok CLI sessions normally.
  8. If Ollama is installed, start local model sessions with:
     helm-gemma
     helm-qwen

When runtime shims are installed, PATH-based codex, claude, grok, or grok-cli launches can route through helm's wrappers, which start the bridge when needed and keep local sessions discoverable. Codex can also launch through the embedded CLI bundled inside Codex.app, so a separate codex binary is optional. Local Gemma and Qwen sessions route through Ollama with helm-gemma or helm-qwen.

${RUNTIME_SHIM_OUTPUT}

${BINARY_CAPTURE_OUTPUT}

If $BIN_DIR is not already on your PATH, add this to your shell profile:
  export PATH="$BIN_DIR:\$PATH"
EOF
