#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_PROJECT="$ROOT_DIR/macos/HelmMac.xcodeproj"
BUILD_DIR="${HELM_MAC_BUILD_DIR:-$ROOT_DIR/build/installer}"
MAC_DERIVED="$BUILD_DIR/macos-derived"
MAC_APP_SOURCE="$MAC_DERIVED/Build/Products/Debug/HelmMac.app"
MAC_APP_DEST="${HELM_MAC_APP_DEST:-/Applications/Helm.app}"
OPEN_APP=1

usage() {
  cat <<'EOF'
Usage: scripts/install-helm-mac-app.sh [--no-open]

Build, install, and optionally open the macOS helm app.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)
      OPEN_APP=0
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd xcodebuild
require_cmd open
require_cmd ditto

mkdir -p "$BUILD_DIR" "$(dirname "$MAC_APP_DEST")"

echo "[helm] Building macOS helm app..."
xcodebuild   -project "$MAC_PROJECT"   -scheme HelmMac   -configuration Debug   -derivedDataPath "$MAC_DERIVED"   build >/dev/null

if [[ ! -d "$MAC_APP_SOURCE" ]]; then
  echo "Expected macOS app bundle not found at $MAC_APP_SOURCE" >&2
  exit 1
fi

echo "[helm] Installing macOS helm app to $MAC_APP_DEST..."
rm -rf "$MAC_APP_DEST"
ditto "$MAC_APP_SOURCE" "$MAC_APP_DEST"

if [[ "$OPEN_APP" -eq 1 ]]; then
  echo "[helm] Opening macOS helm app..."
  open "$MAC_APP_DEST"
  OPEN_SUMMARY="opened the app after install"
else
  OPEN_SUMMARY="left the app installed but closed"
fi

cat <<EOF

helm macOS app install is ready.

App:
  $MAC_APP_DEST

What changed:
  - built the menu bar Mac app locally from macos/HelmMac.xcodeproj
  - installed the app bundle into $(dirname "$MAC_APP_DEST")
  - $OPEN_SUMMARY
EOF
