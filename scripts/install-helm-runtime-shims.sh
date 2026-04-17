#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
SHIM_DIR="${HOME}/.local/share/helm/runtime-shims"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_LABEL="dev.helm.runtime-path"
LAUNCH_AGENT_PATH="${LAUNCH_AGENTS_DIR}/${LAUNCH_AGENT_LABEL}.plist"

mkdir -p "$BIN_DIR" "$SHIM_DIR" "$LAUNCH_AGENTS_DIR"

ln -sf "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$SHIM_DIR/codex"
ln -sf "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$SHIM_DIR/claude"
ln -sf "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$SHIM_DIR/grok"
ln -sf "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$SHIM_DIR/grok-cli"

LAUNCHD_EXISTING_PATH="$(launchctl getenv PATH 2>/dev/null || true)"
PATH_TARGET="$(python3 - "$SHIM_DIR" "$BIN_DIR" "$LAUNCHD_EXISTING_PATH" "${PATH:-}" "$HOME" <<'PY'
import os
import sys

shim_dir = sys.argv[1]
bin_dir = sys.argv[2]
launchd_path = sys.argv[3]
shell_path = sys.argv[4]
home_dir = sys.argv[5]
default_entries = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/Library/Apple/usr/bin",
]

def is_stable(entry: str) -> bool:
    if not entry:
        return False
    normalized = os.path.normpath(entry)
    if normalized.startswith("/tmp/") or normalized.startswith("/var/folders/"):
        return False
    if "/.codex/tmp/" in normalized:
        return False
    if "codex.system/bootstrap" in normalized:
        return False
    if normalized.startswith(os.path.join(home_dir, ".Trash")):
        return False
    return os.path.isdir(normalized)

entries = []
seen = set()
for value in [shim_dir, bin_dir]:
    normalized = os.path.normpath(value)
    if normalized not in seen:
        entries.append(normalized)
        seen.add(normalized)

for raw_path in [launchd_path, shell_path, ":".join(default_entries)]:
    for value in raw_path.split(":"):
        value = value.strip()
        if not is_stable(value):
            continue
        normalized = os.path.normpath(value)
        if normalized in seen:
            continue
        entries.append(normalized)
        seen.add(normalized)

print(":".join(entries))
PY
)"

cat >"$LAUNCH_AGENT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>PATH</string>
    <string>${PATH_TARGET}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

LAUNCHD_STATUS="launchd PATH export enabled"
if [[ "${HELM_SKIP_LAUNCHD_PATH:-0}" == "1" ]]; then
  LAUNCHD_STATUS="runtime shims installed, launchd PATH export skipped"
elif command -v launchctl >/dev/null 2>&1; then
  if ! /bin/launchctl setenv PATH "$PATH_TARGET" >/dev/null 2>&1; then
    LAUNCHD_STATUS="runtime shims installed, but launchd PATH export failed"
  fi

  if ! /bin/launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
    true
  fi

  if ! /bin/launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1; then
    LAUNCHD_STATUS="runtime shims installed, but launchd agent could not be loaded"
  fi
else
  LAUNCHD_STATUS="runtime shims installed, but launchctl is unavailable"
fi

cat <<EOF
helm runtime shims are ready.

Shim directory:
  $SHIM_DIR

Launch agent:
  $LAUNCH_AGENT_PATH

Status:
  $LAUNCHD_STATUS

What changed:
  - PATH-first codex, claude, grok, and grok-cli shims now route through helm
  - launchd PATH is updated for newly launched GUI apps on this Mac
  - GUI apps that use absolute codex, claude, or grok symlinks can also be captured with helm-enable-binary-capture

Next steps:
  1. Relaunch GUI apps like Codex and Claude so they inherit the new PATH.
  2. Run helm-enable-binary-capture if desktop apps still bypass PATH and launch codex or claude by absolute symlink path.
  3. Enable shell integration if you also want new terminal windows to pick up the same shim path automatically.
EOF
