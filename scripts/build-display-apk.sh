#!/bin/bash
# Builds Resources/ukm-display.apk, the receiver of the Mac's second display on Android
# (openspec/changes/add-android-second-display, design D5). Only needed after changing android/display:
# the built APK is in the repository and scripts/build-app.sh just copies it.
#
#   scripts/build-display-apk.sh          # core tests, then the APK
#   scripts/build-display-apk.sh --test   # core tests only (no Android SDK needed)
#
# Needs: Android SDK (ANDROID_HOME, default ~/Library/Android/sdk) with platforms/android-34 and build-tools,
# a JDK, and the same signing key as the motion camera: ~/.config/universalkm/motion-release.keystore (alias
# ukm-motion) with its password in motion-release.pass next to it (or UKM_MOTION_KEYSTORE /
# UKM_MOTION_KEYSTORE_PASS_FILE). The password is read from the file, never passed on the command line.
# Updates install over the old app only with the same key: keep a backup of both files.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/android/display"
OUT="$ROOT/build/display-apk"
rm -rf "$OUT"
mkdir -p "$OUT"/{test-classes,gen,classes,dex}

# MARK: core tests
echo "==> Core tests"
javac --release 11 -d "$OUT/test-classes" $(find "$APP/core" "$APP/test" -name '*.java')
java -cp "$OUT/test-classes" com.universalkm.display.core.CoreTests
[[ "${1:-}" == "--test" ]] && exit 0

# MARK: APK
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -n 1)"
JAR="$SDK/platforms/android-34/android.jar"
[[ -n "$BT" && -f "$JAR" ]] || { echo "Android SDK with platforms/android-34 and build-tools not found at $SDK" >&2; exit 1; }
KS="${UKM_MOTION_KEYSTORE:-$HOME/.config/universalkm/motion-release.keystore}"
PASS_FILE="${UKM_MOTION_KEYSTORE_PASS_FILE:-${KS%.keystore}.pass}"
[[ -f "$KS" && -f "$PASS_FILE" ]] || { echo "Signing key not found: $KS (+ $PASS_FILE)" >&2; exit 1; }

VERSION_CODE="$(sed -n 's/^versionCode=//p' "$APP/version.properties")"
VERSION_NAME="$(sed -n 's/^versionName=//p' "$APP/version.properties")"
echo "==> APK $VERSION_NAME ($VERSION_CODE) with build-tools $(basename "$BT")"

"$BT/aapt2" compile --dir "$APP/res" -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest "$APP/AndroidManifest.xml" \
  --min-sdk-version 31 --target-sdk-version 34 \
  --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
  --java "$OUT/gen" -o "$OUT/base.apk" "$OUT/res.zip"
javac --release 11 -Xlint:-options -classpath "$JAR" -d "$OUT/classes" \
  $(find "$APP/src" "$APP/core" "$OUT/gen" -name '*.java')
"$BT/d8" --release --min-api 31 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
cp "$OUT/base.apk" "$OUT/unsigned.apk"
(cd "$OUT/dex" && zip -q -X "$OUT/unsigned.apk" classes.dex)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --v4-signing-enabled false --ks "$KS" --ks-key-alias ukm-motion --ks-pass "file:$PASS_FILE" \
  --out "$ROOT/Resources/ukm-display.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$ROOT/Resources/ukm-display.apk"
echo "$VERSION_CODE" > "$ROOT/Resources/ukm-display.version"
echo "==> Resources/ukm-display.apk ($(stat -f %z "$ROOT/Resources/ukm-display.apk") bytes), versionCode $VERSION_CODE"
