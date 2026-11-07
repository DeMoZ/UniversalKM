#!/bin/bash
# Builds build/UniversalKM.app from the Swift package and signs it.
#
#   scripts/build-app.sh                # release build
#   CONFIG=debug scripts/build-app.sh   # debug build
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
#
# Signing: macOS ties Accessibility / Input Monitoring grants to the code signature.
# With a stable identity the grants survive rebuilds; with ad-hoc signing ("-")
# every rebuild looks like a new app and the grants have to be given again.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/UniversalKM.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product UniversalKM
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UniversalKM" "$APP/Contents/MacOS/UniversalKM"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -n 1)"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "WARNING: no 'Apple Development' signing identity found; signing ad-hoc." >&2
  echo "WARNING: macOS will forget the Accessibility / Input Monitoring grants after every rebuild." >&2
  echo "WARNING: set SIGN_IDENTITY to a stable identity to keep them (see README)." >&2
fi

echo "==> codesign ($SIGN_IDENTITY)"
codesign --force --options runtime \
  --entitlements "$ROOT/Resources/UniversalKM.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"

echo "==> Built $APP"
