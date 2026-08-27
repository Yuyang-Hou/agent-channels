#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${1:-}"
MODE="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.([0-9]+)$ ]]; then
  echo "usage: $0 <x.y.z-beta.n> [--notarized]" >&2
  exit 2
fi
EXPECTED_BUILD="${BASH_REMATCH[1]}"
[[ -z "$MODE" || "$MODE" == "--notarized" ]] || { echo "invalid mode: $MODE" >&2; exit 2; }

DMG="$SCRIPT_DIR/build/Pijoo-$VERSION-arm64.dmg"
[[ -f "$DMG" ]] || { echo "missing package: $DMG" >&2; exit 1; }
hdiutil verify "$DMG" >/dev/null

if [[ "$MODE" == "--notarized" ]]; then
  codesign --verify --verbose=2 "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pijoo-verify.XXXXXX")"
MOUNT_POINT="$WORK_DIR/mount"
mkdir -p "$MOUNT_POINT"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1
APP="$MOUNT_POINT/Pijoo.app"
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/Pijoo"
SIDECAR="$APP/Contents/MacOS/rogerthat-sidecar"

codesign --verify --deep --strict --verbose=2 "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "dev.pijoo.menubar" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PijooReleaseVersion' "$INFO")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$EXPECTED_BUILD" ]]
SDK_VERSION="$(otool -l "$EXECUTABLE" | awk '$1 == "sdk" { print $2; exit }')"
[[ "${SDK_VERSION%%.*}" -ge 26 ]] || { echo "Pijoo requires macOS SDK 26 or newer, got $SDK_VERSION" >&2; exit 1; }
diff -qr "$ROOT_DIR/skills/pijoo" "$APP/Contents/Resources/skills/pijoo" >/dev/null

CONFIG="$WORK_DIR/state-v2.json"
printf '{}\n' > "$CONFIG"
REQUEST='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"release-check","version":"1"}}}'
RESPONSE="$(printf '%s\n' "$REQUEST" | "$SIDECAR" reply-mcp --config "$CONFIG")"
MCP_VERSION="$(printf '%s' "$RESPONSE" | plutil -extract result.serverInfo.version raw -o - -)"
[[ "$MCP_VERSION" == "$VERSION" ]]

if [[ "$MODE" == "--notarized" ]]; then
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "Verified Pijoo $VERSION package${MODE:+ (notarized)}"
