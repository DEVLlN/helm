#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"
AUTO_START=1
SHOW_LINK=0

usage() {
  cat <<'EOF'
Usage: helm pair [--no-start] [--show-link]

Print a QR code that pairs iPhone Helm with this Mac's bridge.

By default, this starts the bridge first if it is not already reachable.

Options:
  --no-start   Only print a QR if the bridge is already running.
  --show-link  Also print the raw setup link after the QR.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start)
      AUTO_START=0
      shift
      ;;
    --show-link)
      SHOW_LINK=1
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

if [[ -f "$BRIDGE_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BRIDGE_DIR/.env"
  set +a
fi

: "${BRIDGE_PORT:=8787}"
LOCAL_BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT}"

if ! curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
  if [[ "$AUTO_START" -eq 0 ]]; then
    echo "helm bridge is not currently reachable at $LOCAL_BRIDGE_URL" >&2
    exit 1
  fi

  echo "[helm] Bridge is not reachable at $LOCAL_BRIDGE_URL. Starting it now..."
  if ! HELM_PROTOTYPE_SKIP_PAIRING_QR=1 "$ROOT_DIR/scripts/prototype-up.sh"; then
    echo "helm bridge could not be started. Run 'helm status' for details, then retry 'helm pair'." >&2
    exit 1
  fi
fi

if ! curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
  echo "helm bridge is still not reachable at $LOCAL_BRIDGE_URL" >&2
  exit 1
fi

PAIRING_JSON="$(curl -sf "$LOCAL_BRIDGE_URL/api/pairing")"

SETUP_URL="$(python3 - "$PAIRING_JSON" <<'PY'
import json
import sys
from urllib.parse import parse_qs, quote, urlencode, urlparse, urlunparse

def is_loopback(url: str) -> bool:
    host = urlparse(url).hostname or ""
    return host in {"127.0.0.1", "localhost", "::1"}

pairing = json.loads(sys.argv[1])["pairing"]
setup_url = pairing.get("setupURL") or ""
suggested = pairing.get("suggestedBridgeURLs") or []

preferred_bridge = None
for url in suggested:
    if not is_loopback(url):
        preferred_bridge = url
        break

if not preferred_bridge and suggested:
    preferred_bridge = suggested[0]

if not setup_url:
    print("")
    sys.exit(0)

if not preferred_bridge:
    print(setup_url)
    sys.exit(0)

parsed = urlparse(setup_url)
query = parse_qs(parsed.query, keep_blank_values=True)
query["bridge"] = [preferred_bridge]
new_query = urlencode(query, doseq=True, quote_via=quote)
print(urlunparse(parsed._replace(query=new_query)))
PY
)"

if [[ -z "$SETUP_URL" ]]; then
  echo "Unable to derive a helm setup URL from pairing state." >&2
  exit 1
fi

echo
echo "Scan this helm pairing QR with your iPhone:"
echo

swift - "$SETUP_URL" <<'SWIFT'
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let link = CommandLine.arguments[1]
let context = CIContext(options: nil)
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(link.utf8)
filter.correctionLevel = "M"

guard let outputImage = filter.outputImage else {
  fputs("Failed to create QR image.\n", stderr)
  exit(1)
}

let rect = outputImage.extent.integral
let width = Int(rect.width)
let height = Int(rect.height)
let bytesPerRow = width
var bytes = [UInt8](repeating: 0, count: width * height)
let colorSpace = CGColorSpaceCreateDeviceGray()

guard let bitmapContext = CGContext(
  data: &bytes,
  width: width,
  height: height,
  bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: colorSpace,
  bitmapInfo: CGImageAlphaInfo.none.rawValue
) else {
  fputs("Failed to create QR bitmap context.\n", stderr)
  exit(1)
}

guard let cgImage = context.createCGImage(outputImage, from: rect) else {
  fputs("Failed to render QR image.\n", stderr)
  exit(1)
}

bitmapContext.interpolationQuality = .none
bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

let quietZone = 2
let white = "  "
let black = "██"

for _ in 0..<quietZone {
  print(String(repeating: white, count: width + quietZone * 2))
}

for y in 0..<height {
  var line = String(repeating: white, count: quietZone)
  for x in 0..<width {
    let value = bytes[y * bytesPerRow + x]
    line += value < 128 ? black : white
  }
  line += String(repeating: white, count: quietZone)
  print(line)
}

for _ in 0..<quietZone {
  print(String(repeating: white, count: width + quietZone * 2))
}
SWIFT

echo
if [[ "$SHOW_LINK" -eq 1 ]]; then
  echo "Setup link:"
  echo "$SETUP_URL"
fi
