#!/usr/bin/env bash
set -euo pipefail

CAPTURE_FILE="${HELM_RUNTIME_CAPTURE_FILE:-${HOME}/.config/helm/runtime-binary-capture.json}"

if [[ ! -f "$CAPTURE_FILE" ]]; then
  echo "No helm runtime binary capture metadata was found at:"
  echo "  $CAPTURE_FILE"
  exit 0
fi

RESTORE_OUTPUT="$(
  python3 - "$CAPTURE_FILE" <<'PY'
import json
import os
import sys

capture_file = sys.argv[1]
with open(capture_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

restored = []
skipped = []

for runtime, entry in data.items():
    for link in entry.get("links", []):
        path = link.get("path")
        target = link.get("previousTarget")
        if not path or not target:
            skipped.append(f"{runtime}:{path or '<missing>'} (missing metadata)")
            continue
        if os.path.lexists(path) and not os.path.islink(path):
            skipped.append(f"{path} (current path is not a symlink)")
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if os.path.lexists(path):
            os.unlink(path)
        os.symlink(target, path)
        restored.append(f"{path} -> {target}")

print(json.dumps({"restored": restored, "skipped": skipped}, indent=2))
PY
)"

echo "helm absolute runtime capture has been disabled."
echo
echo "Metadata file:"
echo "  $CAPTURE_FILE"
echo
echo "$RESTORE_OUTPUT"
