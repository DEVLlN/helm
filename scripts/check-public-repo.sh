#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=()

record_failure() {
  failures+=("$1")
}

check_top_level_scope() {
  local top_level

  is_allowed_top_level() {
    case "$1" in
      .github|.gitignore|README.md|TESTING.md|bin|bridge|docs|package.json|scripts)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  while IFS= read -r top_level; do
    [[ -n "$top_level" ]] || continue
    if ! is_allowed_top_level "$top_level"; then
      record_failure "unexpected tracked top-level path: $top_level"
    fi
  done < <(git ls-files | cut -d/ -f1 | sort -u)
}

check_forbidden_tracked_paths() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    record_failure "forbidden tracked path: $path"
  done < <(
    git ls-files \
      'ios/**' \
      'macos/**' \
      'watchos/**' \
      'scripts/capture-ios-screens.sh' \
      'scripts/install-helm-mac-app.sh' \
      'scripts/install-local-prototypes.sh' \
      'scripts/new-feedback.sh' \
      'bridge/dist/**' \
      'scripts/__pycache__/**' \
      '**/.DS_Store'
  )
}

check_forbidden_text() {
  local matches
  matches="$(
    git grep -nE '/Users/[^/]+|helm-dev' -- \
      .github \
      README.md \
      TESTING.md \
      bin \
      bridge \
      docs \
      package.json \
      scripts \
      ':(exclude)scripts/check-public-repo.sh' \
      2>/dev/null || true
  )"

  if [[ -n "$matches" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      record_failure "forbidden text match: $line"
    done <<<"$matches"
  fi
}

check_top_level_scope
check_forbidden_tracked_paths
check_forbidden_text

if [[ ${#failures[@]} -gt 0 ]]; then
  printf 'public repo scope check failed:\n' >&2
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "public repo scope check passed."
