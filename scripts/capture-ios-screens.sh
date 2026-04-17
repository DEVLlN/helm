#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ios/Helm.xcodeproj"
SCHEME="Helm"
DEFAULT_SIMULATOR_NAME="${HELM_SIMULATOR_NAME:-iPhone 17 Pro}"
DERIVED_DATA_PATH="${HELM_DERIVED_DATA_PATH:-$ROOT_DIR/.runtime/deriveddata-ios-screens}"
OUTPUT_DIR="${1:-$ROOT_DIR/.runtime/screenshots/ios/$(date +%Y%m%d-%H%M%S)}"
BUNDLE_ID="com.devlin.helm"

find_booted_udid() {
  xcrun simctl list devices booted | sed -nE 's/.*\\(([A-F0-9-]+)\\) \\(Booted\\).*/\\1/p' | head -n1
}

find_named_udid() {
  xcrun simctl list devices available | sed -nE "s/.*${DEFAULT_SIMULATOR_NAME//\//\\/} \\(([A-F0-9-]+)\\) \\(.*/\\1/p" | head -n1
}

SIMULATOR_UDID="${HELM_SIMULATOR_UDID:-$(find_booted_udid)}"

if [[ -z "$SIMULATOR_UDID" ]]; then
  SIMULATOR_UDID="$(find_named_udid)"
  if [[ -z "$SIMULATOR_UDID" ]]; then
    echo "Unable to find a booted simulator or a device named '$DEFAULT_SIMULATOR_NAME'." >&2
    exit 1
  fi

  open -a Simulator >/dev/null 2>&1 || true
  xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b
fi

mkdir -p "$OUTPUT_DIR"

echo "Building helm for simulator $SIMULATOR_UDID..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build >/dev/null

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Helm.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at $APP_PATH" >&2
  exit 1
fi

echo "Installing helm app..."
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"

capture_section() {
  local section="$1"
  local output_path="$OUTPUT_DIR/${section}.png"

  xcrun simctl terminate "$SIMULATOR_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIMULATOR_UDID" "$BUNDLE_ID" -helm-start-section "$section" >/dev/null
  sleep 3
  xcrun simctl io "$SIMULATOR_UDID" screenshot "$output_path" >/dev/null
  echo "$output_path"
}

echo "Capturing sessions, command, and settings..."
for section in sessions command settings; do
  path="$(capture_section "$section")"
  echo "Captured $section -> $path"
done

echo "Done. Screenshots written to $OUTPUT_DIR"
