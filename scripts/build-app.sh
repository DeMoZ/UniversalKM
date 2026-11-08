#!/bin/bash
# Builds build/UniversalKM.app from the Swift package and signs it.
#
#   scripts/build-app.sh                # release build
#   scripts/build-app.sh --zip          # + build/UniversalKM-<version>.zip (the update archive for Sparkle)
#   CONFIG=debug scripts/build-app.sh   # debug build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Signing: macOS ties Accessibility / Input Monitoring grants to the code signature.
# With a stable identity the grants survive rebuilds and updates; with ad-hoc signing ("-")
# every rebuild looks like a new app and the grants have to be given again.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/UniversalKM.app"
MAKE_ZIP=0
[[ "${1:-}" == "--zip" ]] && MAKE_ZIP=1

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product UniversalKM
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/UniversalKM" "$APP/Contents/MacOS/UniversalKM"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon, drawn by scripts/make-icon.swift.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Sparkle (app updates).
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/UniversalKM" 2>/dev/null || true

# Identity: SIGN_IDENTITY, else an Apple Development certificate, else the project's self-signed
# certificate "UniversalKM Self-Signed" (README, "Подпись"), else ad-hoc. Any stable certificate keeps
# the Accessibility grant across rebuilds and updates: macOS ties it to the certificate, not the build.
SELF_SIGNED="UniversalKM Self-Signed"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$SELF_SIGNED\""; then
  SIGN_IDENTITY="$SELF_SIGNED"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "WARNING: no signing certificate found; signing ad-hoc." >&2
  echo "WARNING: macOS will forget the Accessibility / Input Monitoring grants after every rebuild or update." >&2
  echo "WARNING: set SIGN_IDENTITY to a stable identity to keep them (see README)." >&2
fi

sign() { # sign <path> [extra codesign options]
  case "$SIGN_IDENTITY" in
    "Apple Development:"*|"Developer ID Application:"*)
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "${@:2}" "$1" ;;
    *)
      # Ad-hoc or self-signed: no hardened runtime. Its library validation needs a Team ID, which these
      # signatures lack, so dyld would refuse to load Sparkle.framework (as in EnhanceCapCut).
      codesign --force --sign "$SIGN_IDENTITY" "${@:2}" "$1" ;;
  esac
}

echo "==> codesign ($SIGN_IDENTITY)"
# Sparkle inside out, as its documentation lists.
sparkle="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign "$sparkle/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP" --entitlements "$ROOT/Resources/UniversalKM.entitlements"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"

if [[ $MAKE_ZIP == 1 ]]; then
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
  zip="$ROOT/build/UniversalKM-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$APP" "$zip"
  echo "==> Built $zip"
fi
