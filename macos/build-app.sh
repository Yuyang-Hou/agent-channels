#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Agent Channels.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
STAGING="$BUILD_DIR/dmg"
INFO_PLIST="$SCRIPT_DIR/Info.plist"
SOURCE_ICON="$SCRIPT_DIR/branding/agent-channels-logo-draft-e3.png"
MENU_ICON="$SCRIPT_DIR/branding/agent-channels-menubar.svg"
RELEASE_VERSION="${AGENT_CHANNELS_RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :AgentChannelsReleaseVersion' "$INFO_PLIST")}"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
  echo "Invalid release version: $RELEASE_VERSION" >&2
  exit 2
fi
MARKETING_VERSION="${RELEASE_VERSION%%-*}"
DMG="$BUILD_DIR/Agent-Channels-$RELEASE_VERSION-arm64.dmg"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CACHE_DIR="$BUILD_DIR/module-cache"
ICONSET="$BUILD_DIR/AppIcon.iconset"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFT_MODULECACHE_PATH="$CACHE_DIR/swift"

rm -rf "$APP" "$STAGING" "$DMG" "$ICONSET" "$BUILD_DIR/agent-channels-self-test"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$STAGING" "$ICONSET" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH"

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

echo "==> Preparing brand assets"
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${entry%% *}"
  name="${entry#* }"
  sips -s format png -z "$size" "$size" "$SOURCE_ICON" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"
cp "$MENU_ICON" "$RESOURCES_DIR/AgentChannelsMenuBar.svg"

cp "$INFO_PLIST" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :AgentChannelsReleaseVersion $RELEASE_VERSION" "$CONTENTS/Info.plist"
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
echo "Note: this is an ad-hoc signed acceptance build, not a notarized production release."
