#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Agent Channels.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
STAGING="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/Agent-Channels-0.1.0-arm64.dmg"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CACHE_DIR="$BUILD_DIR/module-cache"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFT_MODULECACHE_PATH="$CACHE_DIR/swift"

rm -rf "$APP" "$STAGING" "$DMG" "$BUILD_DIR/agent-channels-self-test"
mkdir -p "$MACOS_DIR" "$STAGING" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

echo "==> Running focused Swift self-test"
swiftc \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -D SELF_TEST \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework SwiftUI \
  "$SCRIPT_DIR/AgentChannelsApp.swift" \
  -o "$BUILD_DIR/agent-channels-self-test"
"$BUILD_DIR/agent-channels-self-test"

echo "==> Compiling RogerThat sidecar"
bun build --compile --target=bun-darwin-arm64 \
  --define 'process.env.AGENT_CHANNELS_EMBEDDED_VERSION="1.25.1-agent-channels.0"' \
  "$ROOT_DIR/server/src/cli.ts" \
  --outfile "$MACOS_DIR/rogerthat-sidecar"

echo "==> Compiling native menu bar app"
swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework Security \
  -framework ServiceManagement \
  -framework SwiftUI \
  "$SCRIPT_DIR/AgentChannelsApp.swift" \
  -o "$MACOS_DIR/Agent Channels"

cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
chmod 755 "$MACOS_DIR/Agent Channels" "$MACOS_DIR/rogerthat-sidecar"

echo "==> Ad-hoc signing local acceptance build"
codesign --force --sign - "$MACOS_DIR/rogerthat-sidecar"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto "$APP" "$STAGING/Agent Channels.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG"
hdiutil create \
  -volname "Agent Channels" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

echo "Built: $APP"
echo "Built: $DMG"
echo "Note: this is an ad-hoc signed local acceptance build, not a notarized public release."
