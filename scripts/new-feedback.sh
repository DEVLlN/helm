#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTS_DIR="$ROOT_DIR/feedback/requests"
TEMPLATE_PATH="$ROOT_DIR/feedback/TEMPLATE.md"

usage() {
  cat <<'EOF'
Usage:
  scripts/new-feedback.sh "title" [/path/to/asset ...]

Examples:
  scripts/new-feedback.sh "command deck spacing"
  scripts/new-feedback.sh "approval card urgency" ~/Desktop/helm-approval.png
EOF
}

if [[ "${1:-}" == "" ]] || [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

TITLE="$1"
shift || true

slugify() {
  python3 - "$1" <<'PY'
import re
import sys

text = sys.argv[1].strip().lower()
text = re.sub(r"[^a-z0-9]+", "-", text)
text = re.sub(r"-{2,}", "-", text).strip("-")
print(text or "feedback")
PY
}

SLUG="$(slugify "$TITLE")"
STAMP="$(date +%F)"
REQUEST_DIR="$REQUESTS_DIR/$STAMP-$SLUG"
ASSETS_DIR="$REQUEST_DIR/assets"
REQUEST_PATH="$REQUEST_DIR/request.md"

if [[ -e "$REQUEST_DIR" ]]; then
  echo "Feedback request already exists: $REQUEST_DIR" >&2
  exit 1
fi

mkdir -p "$ASSETS_DIR"
cp "$TEMPLATE_PATH" "$REQUEST_PATH"

python3 - "$REQUEST_PATH" "$TITLE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
title = sys.argv[2]
content = path.read_text(encoding="utf-8")
content = content.replace("Short statement of the issue or requested change.", title, 1)
path.write_text(content, encoding="utf-8")
PY

ATTACHMENTS=()
for asset in "$@"; do
  if [[ ! -e "$asset" ]]; then
    echo "Asset not found: $asset" >&2
    exit 1
  fi

  target="$ASSETS_DIR/$(basename "$asset")"
  cp -R "$asset" "$target"
  ATTACHMENTS+=("assets/$(basename "$asset")")
done

if [[ "${#ATTACHMENTS[@]}" -gt 0 ]]; then
  python3 - "$REQUEST_PATH" "${ATTACHMENTS[@]}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
attachments = sys.argv[2:]
content = path.read_text(encoding="utf-8")
needle = "List the files in `assets/`."
replacement = "\n".join(f"- {item}" for item in attachments)
content = content.replace(needle, replacement, 1)
path.write_text(content, encoding="utf-8")
PY
fi

echo "Created feedback request:"
echo "  $REQUEST_DIR"
echo
echo "Next:"
echo "  1. Edit $REQUEST_PATH"
echo "  2. Add any more screenshots into $ASSETS_DIR"
echo "  3. Tell Codex the request folder name"
