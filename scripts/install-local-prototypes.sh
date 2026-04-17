#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_PROJECT="$ROOT_DIR/ios/Helm.xcodeproj"
MAC_PROJECT="$ROOT_DIR/macos/HelmMac.xcodeproj"
BUILD_DIR="$ROOT_DIR/build/prototypes"
IOS_DERIVED="$BUILD_DIR/ios-derived"
MAC_DERIVED="$BUILD_DIR/macos-derived"
SIMULATOR_NAME="${HELM_SIMULATOR_NAME:-iPhone 17 Pro}"
MAC_APP_SOURCE="$MAC_DERIVED/Build/Products/Debug/HelmMac.app"
MAC_APP_DEST="/Applications/Helm.app"
IOS_APP_SOURCE="$IOS_DERIVED/Build/Products/Debug-iphonesimulator/Helm.app"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd xcodebuild
require_cmd xcrun
require_cmd open
require_cmd ditto

echo "[helm] Ensuring local prototype services are running..."
"$ROOT_DIR/scripts/prototype-up.sh" >/dev/null

mkdir -p "$BUILD_DIR"

echo "[helm] Building macOS app..."
xcodebuild \
  -project "$MAC_PROJECT" \
  -scheme HelmMac \
  -configuration Debug \
  -derivedDataPath "$MAC_DERIVED" \
  build >/dev/null

if [[ ! -d "$MAC_APP_SOURCE" ]]; then
  echo "Expected macOS app bundle not found at $MAC_APP_SOURCE" >&2
  exit 1
fi

echo "[helm] Installing macOS app to $MAC_APP_DEST..."
rm -rf "$MAC_APP_DEST"
ditto "$MAC_APP_SOURCE" "$MAC_APP_DEST"
open "$MAC_APP_DEST"

echo "[helm] Building iPhone simulator app..."
xcodebuild \
  -project "$IOS_PROJECT" \
  -scheme Helm \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath "$IOS_DERIVED" \
  build >/dev/null

if [[ ! -d "$IOS_APP_SOURCE" ]]; then
  echo "Expected iPhone simulator app bundle not found at $IOS_APP_SOURCE" >&2
  exit 1
fi

SIMULATOR_ID="$(
  xcrun simctl list devices available | python3 - "$SIMULATOR_NAME" <<'PY'
import re
import sys

name = sys.argv[1]
pattern = re.compile(rf"{re.escape(name)} \(([A-F0-9-]+)\)")

for line in sys.stdin:
    match = pattern.search(line)
    if match:
        print(match.group(1))
        break
PY
)"

if [[ -z "$SIMULATOR_ID" ]]; then
  echo "Could not find simulator named: $SIMULATOR_NAME" >&2
  exit 1
fi

echo "[helm] Booting simulator $SIMULATOR_NAME..."
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
open -a Simulator

echo "[helm] Installing iPhone prototype into the simulator..."
xcrun simctl install "$SIMULATOR_ID" "$IOS_APP_SOURCE"
xcrun simctl launch "$SIMULATOR_ID" com.devlin.helm >/dev/null

echo
echo "helm prototypes are ready."
echo
echo "Mac app:"
echo "  $MAC_APP_DEST"
echo
echo "iPhone simulator app:"
echo "  Simulator: $SIMULATOR_NAME"
echo "  Bundle: $IOS_APP_SOURCE"
echo
echo "Note:"
echo "  A real physical iPhone install still needs Apple signing configured in Xcode."
echo "  The simulator build is installed and launched for you now."
