#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/prototype}"
LOG_DIR="$RUNTIME_DIR/logs"
BRIDGE_DIR="$ROOT_DIR/bridge"

if [[ -f "$BRIDGE_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$BRIDGE_DIR/.env"
  set +a
fi

: "${BRIDGE_PORT:=8787}"
LOCAL_BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT}"

if ! curl -sf "$LOCAL_BRIDGE_URL/health" >/dev/null 2>&1; then
  echo "helm bridge is not currently reachable at $LOCAL_BRIDGE_URL" >&2
  echo "Logs: $LOG_DIR" >&2
  exit 1
fi

PAIRING_JSON="$(curl -sf "$LOCAL_BRIDGE_URL/api/pairing")"
HEALTH_JSON="$(curl -sf "$LOCAL_BRIDGE_URL/health")"
PAIRING_TOKEN="${BRIDGE_PAIRING_TOKEN:-$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pairing"].get("token",""))' <<<"$PAIRING_JSON")}"
AUTH_HEADER=()

if [[ -n "$PAIRING_TOKEN" ]]; then
  AUTH_HEADER=(-H "Authorization: Bearer $PAIRING_TOKEN")
fi

VOICE_PROVIDERS_JSON="$(curl -sf "${AUTH_HEADER[@]}" "$LOCAL_BRIDGE_URL/api/voice/providers")"
PERSONAPLEX_BOOTSTRAP_JSON="$(curl -sf "${AUTH_HEADER[@]}" "$LOCAL_BRIDGE_URL/api/voice/providers/personaplex/bootstrap?backendId=codex&style=codex" || true)"

python3 - "$PAIRING_JSON" "$HEALTH_JSON" "$VOICE_PROVIDERS_JSON" "$PERSONAPLEX_BOOTSTRAP_JSON" "$LOCAL_BRIDGE_URL" "$LOG_DIR" <<'PY'
import json
import sys

pairing = json.loads(sys.argv[1])["pairing"]
health = json.loads(sys.argv[2])
voice_providers = json.loads(sys.argv[3]).get("providers", [])
personaplex_bootstrap = json.loads(sys.argv[4]) if sys.argv[4].strip() else None
local_bridge_url = sys.argv[5]
log_dir = sys.argv[6]

print(f"Local bridge: {local_bridge_url}")
print(f"Default backend: {health.get('defaultBackendId', 'unknown')}")
print(f"Pairing token hint: {pairing.get('tokenHint', 'unknown')}")

for url in pairing.get("suggestedBridgeURLs") or []:
    print(f"Suggested bridge URL: {url}")

if pairing.get("setupURL"):
    print(f"Setup link: {pairing['setupURL']}")

if voice_providers:
    print("Voice providers:")
    for provider in voice_providers:
        availability = "available" if provider.get("available") else "unavailable"
        transport = provider.get("transport") or "unknown"
        detail = provider.get("availabilityDetail") or "No detail."
        print(f"  - {provider.get('id', 'unknown')}: {availability} via {transport}")
        print(f"    {detail}")

if personaplex_bootstrap:
    bootstrap = personaplex_bootstrap.get("bootstrap") or {}
    configured = bootstrap.get("configured")
    reachable = bootstrap.get("reachable")
    websocket_url = bootstrap.get("websocketUrl") or "n/a"
    bridge_proxy = (bootstrap.get("bridgeProxy") or {}).get("websocketPath") or "n/a"
    detail = bootstrap.get("detail") or "No detail."
    print("PersonaPlex bootstrap:")
    print(f"  configured: {configured}")
    print(f"  reachable: {reachable}")
    print(f"  websocket: {websocket_url}")
    print(f"  bridge proxy: {bridge_proxy}")
    print(f"  detail: {detail}")

print(f"Logs: {log_dir}")
PY

if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  if [[ -n "$TAILSCALE_IP" ]]; then
    TAILSCALE_BRIDGE_URL="http://${TAILSCALE_IP}:${BRIDGE_PORT}"
    if curl -sf --connect-timeout 2 "$TAILSCALE_BRIDGE_URL/health" >/dev/null 2>&1; then
      echo "Tailscale bridge: $TAILSCALE_BRIDGE_URL reachable"
    else
      echo "Tailscale bridge: $TAILSCALE_BRIDGE_URL not reachable" >&2
    fi
  fi
fi
