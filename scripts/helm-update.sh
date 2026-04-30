#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE_DIR="$ROOT_DIR/bridge"
PACKAGE_NAME="${HELM_NPM_PACKAGE_NAME:-@devlln/helm}"
HOMEBREW_FORMULA="${HELM_HOMEBREW_FORMULA:-devlln/helm/helm}"
METHOD="auto"
SOURCE="manual"
YES=0
DRY_RUN=0
RESTART=1

usage() {
  cat <<'EOF'
Usage: scripts/helm-update.sh [options]

Update the installed Helm bridge package and restart the launchd bridge service.

Options:
  --method auto|npm|homebrew|git  Select the update mechanism. Default: auto.
  --yes                           Do not prompt before updating.
  --dry-run                       Print the update commands without running them.
  --no-restart                    Update without restarting the bridge service.
  --source NAME                   Label the caller in logs. Default: manual.
  -h, --help                      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)
      METHOD="${2:-}"
      shift 2
      ;;
    --yes|-y)
      YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-restart)
      RESTART=0
      shift
      ;;
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[helm-update] would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

detect_method() {
  if [[ "$ROOT_DIR" == *"/Cellar/helm/"* ]] && command -v brew >/dev/null 2>&1; then
    echo "homebrew"
    return
  fi

  if [[ -d "$ROOT_DIR/.git" ]]; then
    echo "git"
    return
  fi

  if command -v npm >/dev/null 2>&1; then
    echo "npm"
    return
  fi

  echo "unknown"
}

resolve_installed_root() {
  local helm_bin
  helm_bin="$(command -v helm || true)"
  if [[ -z "$helm_bin" ]]; then
    printf '%s\n' "$ROOT_DIR"
    return
  fi

  python3 - "$helm_bin" "$ROOT_DIR" <<'PY'
import os
import sys

helm_bin, fallback = sys.argv[1:]
try:
    real = os.path.realpath(helm_bin)
    root = os.path.abspath(os.path.join(os.path.dirname(real), ".."))
    if os.path.exists(os.path.join(root, "scripts", "bridge-service.sh")):
        print(root)
        raise SystemExit(0)
except OSError:
    pass

print(fallback)
PY
}

restart_bridge_service() {
  if [[ "$RESTART" -eq 0 ]]; then
    return
  fi

  local installed_root
  installed_root="$(resolve_installed_root)"
  local service_script="$installed_root/scripts/bridge-service.sh"

  if [[ ! -f "$service_script" ]]; then
    echo "[helm-update] Bridge service script not found; skipping service restart." >&2
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_cmd "$service_script" restart
    return
  fi

  if "$service_script" restart; then
    return
  fi

  echo "[helm-update] Bridge service restart failed. Run 'helm bridge service restart' after the update." >&2
}

METHOD="${METHOD:-auto}"
if [[ "$METHOD" == "auto" ]]; then
  METHOD="$(detect_method)"
fi

case "$METHOD" in
  npm|homebrew|git)
    ;;
  unknown)
    echo "Could not detect how Helm was installed. Reinstall with npm or Homebrew, or pass --method." >&2
    exit 1
    ;;
  *)
    echo "Unsupported update method: $METHOD" >&2
    usage >&2
    exit 2
    ;;
esac

echo "[helm-update] source=${SOURCE} method=${METHOD} root=${ROOT_DIR}"

if [[ "$YES" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Refusing to update without --yes from a non-interactive shell." >&2
    exit 1
  fi

  read -r -p "Update Helm using ${METHOD} and restart the bridge service? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Update cancelled."
      exit 1
      ;;
  esac
fi

case "$METHOD" in
  npm)
    require_cmd npm
    run_cmd npm install -g "${PACKAGE_NAME}@latest"
    ;;
  homebrew)
    require_cmd brew
    run_cmd brew update
    if ! run_cmd brew upgrade "$HOMEBREW_FORMULA"; then
      run_cmd brew reinstall "$HOMEBREW_FORMULA"
    fi
    ;;
  git)
    require_cmd git
    require_cmd npm
    run_cmd git -C "$ROOT_DIR" pull --ff-only
    run_cmd npm --prefix "$BRIDGE_DIR" install
    run_cmd npm --prefix "$BRIDGE_DIR" run build
    ;;
esac

restart_bridge_service
echo "[helm-update] update complete"
