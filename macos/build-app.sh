#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Pijoo.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
STAGING="$BUILD_DIR/dmg"
INFO_PLIST="$SCRIPT_DIR/Info.plist"
SOURCE_ICON="$SCRIPT_DIR/branding/pijoo-logo.png"
MENU_ICON="$SCRIPT_DIR/branding/pijoo-menubar.svg"
SKILL_SOURCE="$ROOT_DIR/skills/pijoo"
DEFAULT_SIGN_IDENTITY="7D4A076571734A0E816D5C522FF9A7286D1C5A50"
REQUESTED_SIGN_IDENTITY="${PIJOO_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
REQUIRE_SIGNING="${PIJOO_REQUIRE_SIGNING:-0}"
RELEASE_VERSION="${PIJOO_RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :PijooReleaseVersion' "$INFO_PLIST")}"
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]]; then
  echo "Invalid release version: $RELEASE_VERSION" >&2
  exit 2
fi
MARKETING_VERSION="${RELEASE_VERSION%%-*}"
DMG="$BUILD_DIR/Pijoo-$RELEASE_VERSION-arm64.dmg"
SDK="${PIJOO_SDK:-${SDKROOT:-}}"
if [[ -z "$SDK" ]]; then
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
elif [[ ! -d "$SDK" ]]; then
  SDK="$(xcrun --sdk "$SDK" --show-sdk-path)"
fi
if [[ ! -f "$SDK/SDKSettings.plist" ]]; then
  echo "Invalid macOS SDK: $SDK" >&2
  exit 2
fi
CACHE_DIR="$BUILD_DIR/module-cache"
ICONSET="$BUILD_DIR/AppIcon.iconset"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFT_MODULECACHE_PATH="$CACHE_DIR/swift"

resolve_sign_identity() {
  local requested="$1"
  local identities index hash label
  local matches=()

  [[ "$requested" == "-" ]] && { echo "-"; return 0; }
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  while read -r index hash label; do
    [[ "$hash" =~ ^[0-9A-F]{40}$ ]] || continue
    if [[ "$requested" =~ ^[0-9A-F]{40}$ ]]; then
      [[ "$hash" == "$requested" ]] && matches+=("$hash")
    else
      [[ "$label" == "\"$requested\"" ]] && matches+=("$hash")
    fi
  done <<< "$identities"

  case "${#matches[@]}" in
    1) echo "${matches[0]}" ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

if SIGN_IDENTITY="$(resolve_sign_identity "$REQUESTED_SIGN_IDENTITY")"; then
  :
else
  resolve_status=$?
  if [[ "$resolve_status" -eq 2 ]]; then
    echo "Signing identity is ambiguous: $REQUESTED_SIGN_IDENTITY" >&2
    exit 2
  fi
  if [[ -n "${PIJOO_SIGN_IDENTITY+x}" || "$REQUIRE_SIGNING" == "1" ]]; then
    echo "Signing identity is unavailable: $REQUESTED_SIGN_IDENTITY" >&2
    exit 2
  fi
  SIGN_IDENTITY="-"
fi

rm -rf "$APP" "$STAGING" "$DMG" "$ICONSET" "$BUILD_DIR/pijoo-self-test" "$BUILD_DIR/pijoo-updater-self-test"
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
  "$SCRIPT_DIR/PijooApp.swift" \
  -o "$BUILD_DIR/pijoo-self-test"
"$BUILD_DIR/pijoo-self-test"

echo "==> Running update helper self-test"
swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  "$SCRIPT_DIR/UpdateHelper.swift" \
  -o "$BUILD_DIR/pijoo-updater-self-test"
"$BUILD_DIR/pijoo-updater-self-test" --self-test

echo "==> Compiling RogerThat sidecar"
bun build --compile --target=bun-darwin-arm64 \
  --define 'process.env.PIJOO_EMBEDDED_VERSION="1.25.1-pijoo.0"' \
  --define "process.env.PIJOO_APP_VERSION=\"$RELEASE_VERSION\"" \
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
  "$SCRIPT_DIR/PijooApp.swift" \
  -o "$MACOS_DIR/Pijoo"

echo "==> Compiling native update helper"
swiftc \
  -O \
  -swift-version 5 \
  -parse-as-library \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macos13.0 \
  -sdk "$SDK" \
  "$SCRIPT_DIR/UpdateHelper.swift" \
  -o "$MACOS_DIR/pijoo-updater"

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
cp "$MENU_ICON" "$RESOURCES_DIR/PijooMenuBar.svg"
mkdir -p "$RESOURCES_DIR/skills"
ditto "$SKILL_SOURCE" "$RESOURCES_DIR/skills/pijoo"

cp "$INFO_PLIST" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PijooReleaseVersion $RELEASE_VERSION" "$CONTENTS/Info.plist"
chmod 755 "$MACOS_DIR/Pijoo" "$MACOS_DIR/rogerthat-sidecar" "$MACOS_DIR/pijoo-updater"

echo "==> Signing with identity: $SIGN_IDENTITY"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" \
  --identifier dev.pijoo.rogerthat-sidecar \
  "$MACOS_DIR/rogerthat-sidecar"
codesign "${SIGN_ARGS[@]}" \
  --identifier dev.pijoo.updater \
  "$MACOS_DIR/pijoo-updater"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
codesign -dv --verbose=4 "$APP" 2>&1 | sed -n '/^Authority=/p; /^TeamIdentifier=/p'

ditto "$APP" "$STAGING/Pijoo.app"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG"
hdiutil create \
  -volname "Pijoo" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

echo "Built: $APP"
echo "Built: $DMG"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Note: this is an ad-hoc signed source build, not a notarized distribution build."
else
  echo "Note: this build has a stable code-signing identity but is not notarized or ready for public distribution."
fi
