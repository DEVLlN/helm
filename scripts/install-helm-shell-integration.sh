#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
SHIM_DIR="${HOME}/.local/share/helm/runtime-shims"
CONFIG_DIR="${HOME}/.config/helm/shell"
SHELL_NAME=""
DRY_RUN=0
EDIT_PROFILE=1
SKIP_CLI_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      SHELL_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-profile-edit)
      EDIT_PROFILE=0
      shift
      ;;
    --skip-cli-install)
      SKIP_CLI_INSTALL=1
      shift
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      echo "Usage: scripts/install-helm-shell-integration.sh [--shell zsh|bash] [--dry-run] [--no-profile-edit] [--skip-cli-install]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SHELL_NAME" ]]; then
  SHELL_NAME="$(basename "${SHELL:-zsh}")"
fi

case "$SHELL_NAME" in
  zsh)
    PROFILE_PATH="${HOME}/.zshrc"
    SNIPPET_PATH="${CONFIG_DIR}/integration.zsh"
    ;;
  bash)
    PROFILE_PATH="${HOME}/.bashrc"
    SNIPPET_PATH="${CONFIG_DIR}/integration.bash"
    ;;
  *)
    echo "Unsupported shell for automatic integration: $SHELL_NAME" >&2
    exit 1
    ;;
esac

mkdir -p "$BIN_DIR" "$CONFIG_DIR"

if [[ "$SKIP_CLI_INSTALL" -eq 0 ]]; then
  "$ROOT_DIR/scripts/install-helm-cli.sh" >/dev/null
fi

SNIPPET_CONTENT=$(cat <<EOF
# Added by helm
export PATH="\$HOME/.local/share/helm/runtime-shims:\$HOME/.local/bin:\$PATH"
EOF
)

SOURCE_LINE="[[ -f \"$SNIPPET_PATH\" ]] && source \"$SNIPPET_PATH\""

if [[ "$DRY_RUN" -eq 1 ]]; then
  cat <<EOF
Would write shell integration snippet:
  $SNIPPET_PATH

Would source it from:
  $PROFILE_PATH

Snippet contents:
$SNIPPET_CONTENT
EOF
  exit 0
fi

printf '%s\n' "$SNIPPET_CONTENT" >"$SNIPPET_PATH"

if [[ "$EDIT_PROFILE" -eq 1 ]]; then
  touch "$PROFILE_PATH"
  if ! grep -Fq "$SOURCE_LINE" "$PROFILE_PATH"; then
    {
      printf '\n# helm shell integration\n'
      printf '%s\n' "$SOURCE_LINE"
    } >>"$PROFILE_PATH"
  fi
fi

cat <<EOF
helm shell integration is ready.

Shell:
  $SHELL_NAME

Snippet:
  $SNIPPET_PATH

Profile:
  $PROFILE_PATH

What changed:
  - ~/.local/share/helm/runtime-shims is added to PATH ahead of other runtime locations
  - ~/.local/bin remains on PATH for helm helper commands
  - codex, claude, grok, and grok-cli now resolve through helm's runtime shims in new shells

Next steps:
  1. Open a new terminal window, or run:
     source "$SNIPPET_PATH"
  2. Start codex, claude, or grok normally; use helm-gemma or helm-qwen for local model shells.
  3. Relaunch GUI apps if you want them to inherit the same shimmed PATH.
EOF
