#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME:-$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')}"
SANDBOX_LINK_ROOT="$ROOT_DIR/.runtime/test-install-sandbox"
LATEST_ROOT_LINK="$SANDBOX_LINK_ROOT/latest-root"
LATEST_ENV_LINK="$SANDBOX_LINK_ROOT/latest-env.sh"
LATEST_RUN_LINK="$SANDBOX_LINK_ROOT/latest-run.sh"
SANDBOX_ROOT=""
KEEP_SANDBOX=1
SHELL_NAME="zsh"
START_RUNTIME=1
RUN_SMOKE=0
RUNTIME_WAS_STARTED=0
ENV_FILE=""
RUN_FILE=""
HEALTH_STATUS="not started"
PAIRING_SUMMARY="not available"
SMOKE_FAILURES=()
SMOKE_PASSES=0

usage() {
  cat <<'EOF'
Usage: scripts/test-install-sandbox.sh [--root PATH] [--cleanup] [--no-runtime-start] [--shell zsh|bash] [--smoke]

Create a disposable temp-HOME sandbox and run the helm installer inside it.

Default behavior:
  - creates an isolated HOME under a temp directory
  - skips launchd PATH mutation and absolute binary capture
  - starts the bridge and Codex app-server on isolated localhost ports
  - keeps the sandbox on disk so you can inspect it afterward
  - refreshes stable repo-local links under .runtime/test-install-sandbox/

Smoke mode:
  - verifies the CLI helpers, runtime shims, and shell integration were installed in the sandbox
  - verifies interactive shell resolution points at the sandbox shims
  - verifies isolated bridge health and pairing artifacts when runtime start is enabled
  - exits non-zero if any assertion fails
EOF
}

clear_latest_links_if_matching() {
  local link="" target="" expected=""
  for link in "$LATEST_ROOT_LINK" "$LATEST_ENV_LINK" "$LATEST_RUN_LINK"; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link" 2>/dev/null || true)"
    expected=""
    case "$link" in
      "$LATEST_ROOT_LINK")
        expected="$SANDBOX_ROOT"
        ;;
      "$LATEST_ENV_LINK")
        expected="$ENV_FILE"
        ;;
      "$LATEST_RUN_LINK")
        expected="$RUN_FILE"
        ;;
    esac
    if [[ -n "$expected" && "$target" == "$expected" ]]; then
      rm -f "$link"
    fi
  done
  rmdir "$SANDBOX_LINK_ROOT" >/dev/null 2>&1 || true
}

cleanup_sandbox() {
  if [[ "$KEEP_SANDBOX" -ne 0 || -z "$SANDBOX_ROOT" ]]; then
    return
  fi

  if [[ "$RUNTIME_WAS_STARTED" -eq 1 && -n "$RUN_FILE" && -x "$RUN_FILE" ]]; then
    "$RUN_FILE" "$ROOT_DIR/scripts/prototype-down.sh" >/dev/null 2>&1 || true
  fi

  clear_latest_links_if_matching
  rm -rf "$SANDBOX_ROOT"
}

trap cleanup_sandbox EXIT

smoke_ok() {
  printf '[smoke] ok: %s\n' "$1"
  SMOKE_PASSES=$((SMOKE_PASSES + 1))
}

smoke_fail() {
  printf '[smoke] fail: %s\n' "$1" >&2
  SMOKE_FAILURES+=("$1")
}

assert_exists() {
  local path="$1"
  local label="$2"
  if [[ -e "$path" ]]; then
    smoke_ok "$label"
  else
    smoke_fail "$label (missing: $path)"
  fi
}

assert_not_exists() {
  local path="$1"
  local label="$2"
  if [[ ! -e "$path" ]]; then
    smoke_ok "$label"
  else
    smoke_fail "$label (unexpected path exists: $path)"
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    smoke_ok "$label"
  else
    smoke_fail "$label (expected: $expected, got: $actual)"
  fi
}

assert_command() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    smoke_ok "$label"
  else
    smoke_fail "$label"
  fi
}

assert_apply_patch_passthrough() {
  local label="$1"
  local expected_arg="$2"
  shift 2

  local marker_file="$SANDBOX_ROOT/apply-patch-marker-${SMOKE_PASSES}-${RANDOM}.txt"
  rm -f "$marker_file"

  if HELM_REAL_CODEX_PATH="$SMOKE_REAL_CODEX_PATH" HELM_APPLY_PATCH_MARKER="$marker_file" "$@" >/dev/null 2>&1; then
    if [[ -s "$marker_file" ]] && grep -Fq -- "$expected_arg" "$marker_file"; then
      smoke_ok "$label"
    else
      smoke_fail "$label (passthrough marker missing: $expected_arg)"
    fi
  else
    smoke_fail "$label"
  fi
}

run_smoke_checks() {
  assert_exists "$SANDBOX_HOME/.local/bin/helm" "helm CLI was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-install" "helm-install helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-platforms" "helm-platforms helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-codex" "helm-codex helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-claude" "helm-claude helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-grok" "helm-grok helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-gemma" "helm-gemma helper was installed"
  assert_exists "$SANDBOX_HOME/.local/bin/helm-qwen" "helm-qwen helper was installed"
  assert_exists "$SANDBOX_HOME/.local/share/helm/runtime-shims/codex" "Codex runtime shim was installed"
  assert_exists "$SANDBOX_HOME/.local/share/helm/runtime-shims/claude" "Claude runtime shim was installed"
  assert_exists "$SANDBOX_HOME/.local/share/helm/runtime-shims/grok" "Grok runtime shim was installed"
  assert_exists "$SANDBOX_HOME/.local/share/helm/runtime-shims/grok-cli" "Grok CLI runtime shim was installed"
  assert_exists "$SANDBOX_HOME/.config/helm/shell/integration.$SHELL_NAME" "shell integration snippet was written"
  assert_not_exists "$SANDBOX_HOME/.config/helm/runtime-binary-capture.json" "absolute binary capture stayed disabled in sandbox"

  assert_command "helm help succeeds in the sandbox" "$SANDBOX_HOME/.local/bin/helm" help
  assert_command "helm platforms --json succeeds in the sandbox" "$SANDBOX_HOME/.local/bin/helm" platforms --json

  local shell_resolution codex_resolved claude_resolved grok_resolved
  if shell_resolution="$("$RUN_FILE" "$SHELL_NAME" -ic 'printf "CODEX=%s\nCLAUDE=%s\nGROK=%s\n" "$(command -v codex)" "$(command -v claude)" "$(command -v grok)"' 2>/dev/null)"; then
    codex_resolved="$(printf '%s\n' "$shell_resolution" | awk -F= '/^CODEX=/{print $2; exit}')"
    claude_resolved="$(printf '%s\n' "$shell_resolution" | awk -F= '/^CLAUDE=/{print $2; exit}')"
    grok_resolved="$(printf '%s\n' "$shell_resolution" | awk -F= '/^GROK=/{print $2; exit}')"
    assert_equals "$codex_resolved" "$SANDBOX_HOME/.local/share/helm/runtime-shims/codex" "interactive $SHELL_NAME resolves Codex through the sandbox shim"
    assert_equals "$claude_resolved" "$SANDBOX_HOME/.local/share/helm/runtime-shims/claude" "interactive $SHELL_NAME resolves Claude through the sandbox shim"
    assert_equals "$grok_resolved" "$SANDBOX_HOME/.local/share/helm/runtime-shims/grok" "interactive $SHELL_NAME resolves Grok through the sandbox shim"
  else
    smoke_fail "interactive $SHELL_NAME resolves the sandbox shims"
  fi

  assert_apply_patch_passthrough \
    "captured codex bypasses helm for --codex-run-as-apply-patch" \
    "--codex-run-as-apply-patch" \
    "$SANDBOX_HOME/.local/share/helm/runtime-shims/codex" \
    --codex-run-as-apply-patch smoke-flag

  assert_apply_patch_passthrough \
    "apply_patch alias bypasses helm and reaches the real Codex binary" \
    "smoke-alias" \
    "$SANDBOX_ROOT/apply_patch" \
    smoke-alias

  assert_apply_patch_passthrough \
    "applypatch alias bypasses helm and reaches the real Codex binary" \
    "smoke-legacy-alias" \
    "$SANDBOX_ROOT/applypatch" \
    smoke-legacy-alias

  if [[ "$START_RUNTIME" -eq 1 ]]; then
    assert_equals "$HEALTH_STATUS" "ok" "isolated bridge health is ok"
    assert_exists "$PAIRING_FILE" "pairing payload was written"
    assert_command "prototype-status succeeds inside the sandbox" "$RUN_FILE" "$ROOT_DIR/scripts/prototype-status.sh"
  fi

  if [[ ${#SMOKE_FAILURES[@]} -gt 0 ]]; then
    printf '\n[smoke] %d assertion(s) failed.\n' "${#SMOKE_FAILURES[@]}" >&2
    printf '[smoke] sandbox root: %s\n' "$SANDBOX_ROOT" >&2
    return 1
  fi

  printf '\n[smoke] all %d assertions passed.\n' "$SMOKE_PASSES"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      SANDBOX_ROOT="${2:-}"
      shift 2
      ;;
    --cleanup)
      KEEP_SANDBOX=0
      shift
      ;;
    --no-mac-app)
      # Compatibility no-op: the public repo is bridge-only.
      shift
      ;;
    --no-runtime-start)
      START_RUNTIME=0
      shift
      ;;
    --shell)
      SHELL_NAME="${2:-}"
      shift 2
      ;;
    --smoke)
      RUN_SMOKE=1
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

if [[ -z "$SANDBOX_ROOT" ]]; then
  SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/helm-install-sandbox.XXXXXX")"
else
  mkdir -p "$SANDBOX_ROOT"
fi

SANDBOX_HOME="$SANDBOX_ROOT/home"
SANDBOX_RUNTIME="$SANDBOX_ROOT/runtime/prototype"
SMOKE_REAL_CODEX_PATH="$SANDBOX_ROOT/fake-real-codex"
PAIRING_FILE="$SANDBOX_HOME/Library/Application Support/Helm/bridge-pairing.json"

mkdir -p "$SANDBOX_HOME" "$SANDBOX_RUNTIME"

if [[ "$RUN_SMOKE" -eq 1 ]]; then
  cat >"$SMOKE_REAL_CODEX_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${HELM_APPLY_PATCH_MARKER:?}"
EOF
  chmod +x "$SMOKE_REAL_CODEX_PATH"
fi

read BRIDGE_PORT APP_SERVER_PORT < <(python3 - <<'PY2'
import socket
ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    ports.append(sock.getsockname()[1])
    sock.close()
print(*ports)
PY2
)

REAL_CODEX_PATH="${HELM_REAL_CODEX_PATH:-}"
REAL_CLAUDE_PATH="${HELM_REAL_CLAUDE_PATH:-}"
if [[ -z "$REAL_CODEX_PATH" || -z "$REAL_CLAUDE_PATH" ]]; then
  read -r CAPTURED_CODEX CAPTURED_CLAUDE < <(python3 - "$REAL_HOME" <<'PY2'
import json
import os
import sys
home = sys.argv[1]
capture_path = os.path.join(home, '.config', 'helm', 'runtime-binary-capture.json')
codex = ''
claude = ''
if os.path.exists(capture_path):
    try:
        with open(capture_path, 'r', encoding='utf-8') as handle:
            data = json.load(handle)
        codex = ((data.get('codex') or {}).get('realPath') or '').strip()
        claude = ((data.get('claude') or {}).get('realPath') or '').strip()
    except Exception:
        pass
print(codex, claude)
PY2
  )
  [[ -n "$REAL_CODEX_PATH" ]] || REAL_CODEX_PATH="$CAPTURED_CODEX"
  [[ -n "$REAL_CLAUDE_PATH" ]] || REAL_CLAUDE_PATH="$CAPTURED_CLAUDE"
fi

CLEAN_PATH="$(python3 - "$REAL_HOME" "${PATH:-}" <<'PY2'
import os
import sys
real_home, path_value = sys.argv[1:]
blocked = {
    os.path.normpath(os.path.join(real_home, '.local', 'bin')),
    os.path.normpath(os.path.join(real_home, '.local', 'share', 'helm', 'runtime-shims')),
}
entries = []
seen = set()
for raw in path_value.split(':'):
    raw = raw.strip()
    if not raw:
        continue
    normalized = os.path.normpath(raw)
    if normalized in blocked:
        continue
    if normalized in seen:
        continue
    entries.append(raw)
    seen.add(normalized)
print(':'.join(entries))
PY2
)"

ENV_FILE="$SANDBOX_ROOT/sandbox-env.sh"
RUN_FILE="$SANDBOX_ROOT/sandbox-run.sh"
cat >"$ENV_FILE" <<EOF
export HOME="$SANDBOX_HOME"
export PATH="$SANDBOX_HOME/.local/share/helm/runtime-shims:$SANDBOX_HOME/.local/bin:$CLEAN_PATH"
export HELM_SKIP_LAUNCHD_PATH=1
export HELM_SKIP_BINARY_CAPTURE=1
export HELM_PROTOTYPE_RUNTIME_DIR="$SANDBOX_RUNTIME"
export BRIDGE_PORT="$BRIDGE_PORT"
export CODEX_APP_SERVER_URL="ws://127.0.0.1:$APP_SERVER_PORT"
export BRIDGE_PAIRING_FILE="$PAIRING_FILE"
export HELM_REAL_CODEX_PATH="$REAL_CODEX_PATH"
export HELM_REAL_CLAUDE_PATH="$REAL_CLAUDE_PATH"
EOF

cat >"$RUN_FILE" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ENV_FILE"
exec "\$@"
EOF
chmod +x "$RUN_FILE"

mkdir -p "$SANDBOX_LINK_ROOT"
rm -f "$LATEST_ROOT_LINK" "$LATEST_ENV_LINK" "$LATEST_RUN_LINK"
ln -s "$SANDBOX_ROOT" "$LATEST_ROOT_LINK"
ln -s "$ENV_FILE" "$LATEST_ENV_LINK"
ln -s "$RUN_FILE" "$LATEST_RUN_LINK"

INSTALL_ARGS=(--shell "$SHELL_NAME")

(
  export HOME="$SANDBOX_HOME"
  export PATH="$CLEAN_PATH"
  export HELM_SKIP_LAUNCHD_PATH=1
  export HELM_SKIP_BINARY_CAPTURE=1
  export HELM_PROTOTYPE_RUNTIME_DIR="$SANDBOX_RUNTIME"
  export BRIDGE_PORT="$BRIDGE_PORT"
  export CODEX_APP_SERVER_URL="ws://127.0.0.1:$APP_SERVER_PORT"
  export BRIDGE_PAIRING_FILE="$PAIRING_FILE"
  export HELM_REAL_CODEX_PATH="$REAL_CODEX_PATH"
  export HELM_REAL_CLAUDE_PATH="$REAL_CLAUDE_PATH"
  if [[ "$START_RUNTIME" -eq 0 ]]; then
    export HELM_INSTALL_SKIP_RUNTIME_START=1
  fi
  "$ROOT_DIR/scripts/install-helm.sh" "${INSTALL_ARGS[@]}"
)

if [[ "$RUN_SMOKE" -eq 1 ]]; then
  ln -sf "$SANDBOX_HOME/.local/share/helm/runtime-shims/codex" "$SANDBOX_ROOT/apply_patch"
  ln -sf "$SANDBOX_HOME/.local/share/helm/runtime-shims/codex" "$SANDBOX_ROOT/applypatch"
fi

if [[ "$START_RUNTIME" -eq 1 ]]; then
  RUNTIME_WAS_STARTED=1
  HEALTH_STATUS="$(python3 - "$BRIDGE_PORT" <<'PY2'
import json
import sys
import urllib.request
port = sys.argv[1]
try:
    data = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=3))
    print('ok' if data.get('ok') else 'not-ok')
except Exception:
    print('unreachable')
PY2
  )"
  if [[ -f "$PAIRING_FILE" ]]; then
    PAIRING_SUMMARY="present at $PAIRING_FILE"
  fi
fi

if [[ "$RUN_SMOKE" -eq 1 ]]; then
  run_smoke_checks
fi

cat <<EOF

helm installer sandbox is ready.

Sandbox root:
  $SANDBOX_ROOT

Sandbox home:
  $SANDBOX_HOME

Sandbox bridge:
  http://127.0.0.1:$BRIDGE_PORT

Sandbox Codex app-server:
  ws://127.0.0.1:$APP_SERVER_PORT

Runtime status:
  $HEALTH_STATUS

Pairing:
  $PAIRING_SUMMARY

Sandbox retention:
  $(if [[ "$KEEP_SANDBOX" -eq 1 ]]; then echo "kept on disk for inspection"; else echo "will be removed on exit (--cleanup)"; fi)

Useful files:
  env: $ENV_FILE
  runner: $RUN_FILE
  stable env link: $LATEST_ENV_LINK
  stable runner link: $LATEST_RUN_LINK

Examples:
  source "$ENV_FILE"
  "$RUN_FILE" "$ROOT_DIR/scripts/prototype-status.sh"
  "$RUN_FILE" zsh -ic 'command -v codex && command -v claude && ls -la ~/.local/bin'
  source "$LATEST_ENV_LINK"
  "$LATEST_RUN_LINK" "$ROOT_DIR/scripts/prototype-status.sh"
EOF
