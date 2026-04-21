#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"
SERVICE_LABEL="dev.helm.bridge"
PLIST_PATH="${HOME}/Library/LaunchAgents/${SERVICE_LABEL}.plist"
RUNTIME_DIR="${HELM_PROTOTYPE_RUNTIME_DIR:-$ROOT_DIR/.runtime/launchd}"
LOG_DIR="$RUNTIME_DIR/logs"
STDOUT_LOG="$LOG_DIR/helm-bridge-service.out.log"
STDERR_LOG="$LOG_DIR/helm-bridge-service.err.log"

for candidate in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  if [[ -d "$candidate" ]] && [[ ":$PATH:" != *":$candidate:"* ]]; then
    PATH="$candidate:$PATH"
  fi
done
export PATH

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
GUI_DOMAIN="gui/$(id -u)"

usage() {
  cat <<'EOF'
Usage: scripts/bridge-service.sh <command>

Commands:
  install      Build the bridge, install the launch agent, and load it.
  uninstall    Unload the launch agent and remove the plist.
  start        Kickstart the installed launch agent.
  stop         Unload the installed launch agent.
  restart      Reload the launch agent from the current plist.
  status       Print launchd and bridge health status.
  print-plist  Print the launch agent plist without installing it.
EOF
}

require_node() {
  if [[ -z "$NODE_BIN" ]]; then
    echo "node is required to run the helm bridge service" >&2
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$(dirname "$PLIST_PATH")" "$LOG_DIR"
}

build_bridge() {
  require_node
  (
    cd "$BRIDGE_DIR"
    npm install >/dev/null
    npm run build >/dev/null
  )
}

launchctl_print_target() {
  echo "${GUI_DOMAIN}/${SERVICE_LABEL}"
}

render_plist() {
  local path_value="$PATH"
  for candidate in "$HOME/.local/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
    if [[ -d "$candidate" ]] && [[ ":$path_value:" != *":$candidate:"* ]]; then
      path_value="$candidate:$path_value"
    fi
  done

  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${SERVICE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${BRIDGE_DIR}/dist/index.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${BRIDGE_DIR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${path_value}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF
}

write_plist() {
  ensure_dirs
  render_plist > "$PLIST_PATH"
}

bootout_if_loaded() {
  /bin/launchctl bootout "$GUI_DOMAIN" "$PLIST_PATH" >/dev/null 2>&1 || true
}

cmd="${1:-}"
case "$cmd" in
  install)
    build_bridge
    write_plist
    bootout_if_loaded
    /bin/launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
    /bin/launchctl enable "$(launchctl_print_target)" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "$(launchctl_print_target)"
    echo "Installed ${SERVICE_LABEL}"
    ;;
  uninstall)
    bootout_if_loaded
    rm -f "$PLIST_PATH"
    echo "Removed ${SERVICE_LABEL}"
    ;;
  start)
    [[ -f "$PLIST_PATH" ]] || { echo "Missing ${PLIST_PATH}" >&2; exit 1; }
    /bin/launchctl kickstart -k "$(launchctl_print_target)"
    echo "Started ${SERVICE_LABEL}"
    ;;
  stop)
    [[ -f "$PLIST_PATH" ]] || { echo "Missing ${PLIST_PATH}" >&2; exit 1; }
    /bin/launchctl bootout "$GUI_DOMAIN" "$PLIST_PATH"
    echo "Stopped ${SERVICE_LABEL}"
    ;;
  restart)
    [[ -f "$PLIST_PATH" ]] || { echo "Missing ${PLIST_PATH}" >&2; exit 1; }
    bootout_if_loaded
    /bin/launchctl bootstrap "$GUI_DOMAIN" "$PLIST_PATH"
    /bin/launchctl kickstart -k "$(launchctl_print_target)"
    echo "Restarted ${SERVICE_LABEL}"
    ;;
  status)
    echo "Label: ${SERVICE_LABEL}"
    echo "Plist: ${PLIST_PATH}"
    if [[ -f "$PLIST_PATH" ]]; then
      echo "Plist status: installed"
    else
      echo "Plist status: missing"
    fi
    if /bin/launchctl print "$(launchctl_print_target)" >/dev/null 2>&1; then
      echo "Launchd status: loaded"
    else
      echo "Launchd status: not loaded"
    fi
    if curl -sf "http://127.0.0.1:8787/health" >/dev/null 2>&1; then
      echo "Bridge health: reachable"
    else
      echo "Bridge health: unreachable"
    fi
    ;;
  print-plist)
    require_node
    render_plist
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
