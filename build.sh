#!/bin/bash
# Builds "Anker Controller.app" into ./dist. No Xcode project needed; uses Swift Package Manager.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Anker Controller"
OUT="dist"
APP="$OUT/$APP_NAME.app"

# --- Deployment target ------------------------------------------------------
# The app needs macOS 14 (Observation, Swift Charts). We never target newer than the Mac we build on.
DETECTED="$(sw_vers -productVersion)"
DETECTED_MAJOR="${DETECTED%%.*}"
REQUIRED_MAJOR=14
if [ "$DETECTED_MAJOR" -lt "$REQUIRED_MAJOR" ]; then
  echo "error: macOS $DETECTED is too old; this app needs macOS $REQUIRED_MAJOR or later." >&2
  exit 1
fi
MIN_OS="$REQUIRED_MAJOR.0"
echo "==> Detected macOS $DETECTED ($(uname -m)); deployment target $MIN_OS (Package.swift: .macOS(.v14))"

# --- Compile ----------------------------------------------------------------
echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/AnkerController"
[ -x "$BIN" ] || { echo "error: binary not found at $BIN" >&2; exit 1; }

# --- Icon -------------------------------------------------------------------
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> Generating app icon"
  TMP="$(mktemp -d)"
  swift scripts/make_icon.swift "$TMP/AppIcon.iconset"
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

# --- Bundle -----------------------------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AnkerController"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__MIN_OS__/$MIN_OS/" Resources/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# --- Sign (ad-hoc only) -------------------------------------------------------
# Ad-hoc signature: lets the app run on THIS Mac and gives macOS a stable identity for the Bluetooth /
# Local Network permission prompts. It is NOT a Developer ID signature and the app is NOT notarized.
echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature structure OK (ad-hoc, not notarized)"

echo
echo "Built: $PWD/$APP"
echo "Open it from Finder, or:  open \"$APP\""
