#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

increment_beta() {
  local base="$1"
  local latest="${2:-}"
  local escaped_base="${base//./\\.}"
  local next=1

  [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  if [[ -n "$latest" ]]; then
    [[ "$latest" =~ ^v${escaped_base}-beta\.([0-9]+)$ ]] || return 2
    next=$((10#${BASH_REMATCH[1]} + 1))
  fi
  printf '%s-beta.%d\n' "$base" "$next"
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$(increment_beta 0.3.0 v0.3.0-beta.20)" == "0.3.0-beta.21" ]]
  [[ "$(increment_beta 1.0.0 '')" == "1.0.0-beta.1" ]]
  if increment_beta 0.3.0 v0.4.0-beta.1 >/dev/null 2>&1; then
    echo "mismatched beta tag was accepted" >&2
    exit 1
  fi
  echo "next beta version self-test passed"
  exit 0
fi

BASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SCRIPT_DIR/Info.plist")"
LATEST_TAG="$(git -C "$ROOT_DIR" tag --list "v${BASE_VERSION}-beta.*" --sort=-v:refname | head -n 1)"
increment_beta "$BASE_VERSION" "$LATEST_TAG"
