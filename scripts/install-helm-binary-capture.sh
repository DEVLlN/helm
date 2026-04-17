#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_DIR="${HOME}/.local/share/helm/runtime-shims"
CONFIG_DIR="${HOME}/.config/helm"
CAPTURE_FILE="${CONFIG_DIR}/runtime-binary-capture.json"

if [[ "${HELM_SKIP_BINARY_CAPTURE:-0}" == "1" ]]; then
  echo "helm absolute runtime capture skipped."
  echo
  echo "Reason:"
  echo "  HELM_SKIP_BINARY_CAPTURE=1"
  echo
  echo "What changed:"
  echo "  - runtime shims can still be installed and tested"
  echo "  - standard absolute codex/claude/grok symlink capture was intentionally not modified"
  exit 0
fi

mkdir -p "$CONFIG_DIR"

if [[ ! -e "$SHIM_DIR/codex" || ! -e "$SHIM_DIR/claude" || ! -e "$SHIM_DIR/grok" || ! -e "$SHIM_DIR/grok-cli" ]]; then
  "$ROOT_DIR/scripts/install-helm-runtime-shims.sh" >/dev/null
fi

record_capture() {
  local runtime="$1"
  local link_path="$2"
  local previous_target="$3"
  local real_path="$4"

  python3 - "$CAPTURE_FILE" "$runtime" "$link_path" "$previous_target" "$real_path" <<'PY'
import json
import os
import sys
import time

capture_file, runtime, link_path, previous_target, real_path = sys.argv[1:]

data = {}
if os.path.exists(capture_file):
    try:
        with open(capture_file, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        data = {}

entry = data.get(runtime) or {}
links = [item for item in entry.get("links", []) if item.get("path") != link_path]
links.append(
    {
        "path": link_path,
        "previousTarget": previous_target,
        "capturedAt": int(time.time() * 1000),
    }
)

entry["links"] = links
entry["realPath"] = real_path
data[runtime] = entry

with open(capture_file, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

is_helm_managed_target() {
  local target_path="$1"
  python3 - "$target_path" "$ROOT_DIR/scripts/helm-runtime-shim.sh" "$ROOT_DIR/scripts/helm-runtime-wrapper.sh" <<'PY'
import os
import sys

target_path, shim_script, wrapper_script = sys.argv[1:]

if not target_path:
    raise SystemExit(1)

try:
    target_real = os.path.realpath(target_path)
except OSError:
    raise SystemExit(1)

managed = set()
for candidate in (shim_script, wrapper_script):
    try:
        managed.add(os.path.realpath(candidate))
    except OSError:
        continue

if target_real in managed:
    raise SystemExit(0)

raise SystemExit(1)
PY
}

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

try:
    print(os.path.realpath(sys.argv[1]))
except OSError:
    print("")
PY
}

candidate_paths() {
  case "$1" in
    codex)
      printf '%s\n' \
        "/opt/homebrew/bin/codex" \
        "/usr/local/bin/codex" \
        "$HOME/.local/bin/codex"
      ;;
    claude)
      printf '%s\n' \
        "$HOME/.local/bin/claude" \
        "/opt/homebrew/bin/claude" \
        "/usr/local/bin/claude"
      ;;
    grok)
      printf '%s\n' \
        "$HOME/.local/bin/grok" \
        "$HOME/.local/bin/grok-cli" \
        "/opt/homebrew/bin/grok" \
        "/opt/homebrew/bin/grok-cli" \
        "/usr/local/bin/grok" \
        "/usr/local/bin/grok-cli"
      ;;
    *)
      return 1
      ;;
  esac
}

captured_lines=()
skipped_lines=()

while IFS= read -r runtime; do
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ -e "$candidate" ]] || continue

    if [[ ! -L "$candidate" ]]; then
      skipped_lines+=("$candidate (exists but is not a symlink)")
      continue
    fi

    current_target="$(readlink "$candidate")"
    resolved_target="$(canonical_path "$candidate")"
    if [[ -z "$resolved_target" || ! -x "$resolved_target" ]]; then
      skipped_lines+=("$candidate (target is not executable)")
      continue
    fi

    if is_helm_managed_target "$candidate"; then
      skipped_lines+=("$candidate (already routes through helm)")
      continue
    fi

    shim_name="$runtime"
    if [[ "$runtime" == "grok" && "$(basename "$candidate")" == "grok-cli" ]]; then
      shim_name="grok-cli"
    fi

    if ln -sfn "$SHIM_DIR/$shim_name" "$candidate"; then
      record_capture "$runtime" "$candidate" "$current_target" "$resolved_target"
      captured_lines+=("$candidate -> $SHIM_DIR/$shim_name")
    else
      skipped_lines+=("$candidate (failed to repoint to helm shim)")
    fi
  done < <(candidate_paths "$runtime")
done <<'EOF'
codex
claude
grok
EOF

echo "helm absolute runtime capture is ready."
echo
echo "Capture file:"
echo "  $CAPTURE_FILE"
echo
echo "Updated launch paths:"
if [[ ${#captured_lines[@]} -eq 0 ]]; then
  echo "  none"
else
  for line in "${captured_lines[@]}"; do
    echo "  $line"
  done
fi
echo
echo "Skipped paths:"
if [[ ${#skipped_lines[@]} -eq 0 ]]; then
  echo "  none"
else
  for line in "${skipped_lines[@]}"; do
    echo "  $line"
  done
fi
echo
echo "What changed:"
echo "  - standard absolute codex/claude/grok launch symlinks now route through helm when they exist"
echo "  - helm records the real underlying runtime so wrappers can avoid recursion"
echo "  - signed app bundles are left untouched"
