#!/bin/bash
# Builds Resources/ukm-motion.apk, the motion camera app for Android
# (openspec/changes/add-android-motion-camera, design D1, D2). Only needed after changing android/motion-camera:
# the built APK is in the repository and scripts/build-app.sh just copies it.
#
#   scripts/build-motion-apk.sh          # core tests, then the APK
#   scripts/build-motion-apk.sh --test   # core tests only (no Android SDK needed; ffmpeg for the MP4 checks)
#
# Needs: Android SDK (ANDROID_HOME, default ~/Library/Android/sdk) with platforms/android-34 and build-tools,
# a JDK, and the signing key ~/.config/universalkm/motion-release.keystore (alias ukm-motion) with its password
# in motion-release.pass next to it (or UKM_MOTION_KEYSTORE / UKM_MOTION_KEYSTORE_PASS_FILE). The password is
# read from the file, never passed on the command line. Updates install over the old app only with the same
# key: keep a backup of both files.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/android/motion-camera"
OUT="$ROOT/build/motion-apk"
rm -rf "$OUT"
mkdir -p "$OUT"/{test-classes,gen,classes,dex}

# MARK: core tests
echo "==> Core tests"
javac --release 11 -d "$OUT/test-classes" $(find "$APP/core" "$APP/test" -name '*.java')
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
  ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=30 -t 4 -c:v libx264 -bf 0 -g 30 \
    -pix_fmt yuv420p -bsf:v h264_metadata=aud=insert -f h264 "$OUT/test.h264"
  java -cp "$OUT/test-classes" com.universalkm.motion.core.CoreTests "$OUT/test.h264" "$OUT/mp4"
  frames() { ffprobe -v quiet -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$1"; }
  duration() { ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 "$1"; }
  full=$(frames "$OUT/mp4/full.mp4"); cut=$(frames "$OUT/mp4/cut.mp4" 2>/dev/null || echo 0)
  echo "    full.mp4: $full frames, $(duration "$OUT/mp4/full.mp4") s; cut.mp4 (power loss): $cut frames"
  [[ "$full" == 120 ]] || { echo "FAIL: full.mp4 should have 120 frames" >&2; exit 1; }
  [[ "$cut" -ge 30 ]] || { echo "FAIL: a cut file should play up to its last whole fragment" >&2; exit 1; }
else
  echo "    (ffmpeg not found: MP4 writer checks skipped)"
  java -cp "$OUT/test-classes" com.universalkm.motion.core.CoreTests
fi
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
"$BT/apksigner" sign --ks "$KS" --ks-key-alias ukm-motion --ks-pass "file:$PASS_FILE" \
  --out "$ROOT/Resources/ukm-motion.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$ROOT/Resources/ukm-motion.apk"
echo "$VERSION_CODE" > "$ROOT/Resources/ukm-motion.version"
echo "==> Resources/ukm-motion.apk ($(stat -f %z "$ROOT/Resources/ukm-motion.apk") bytes), versionCode $VERSION_CODE"
