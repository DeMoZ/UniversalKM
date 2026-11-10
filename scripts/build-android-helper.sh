#!/bin/bash
# Builds Resources/ukm-clipboard.jar (classes.dex) from android/clipboard-helper
# (add-android-clipboard-sync design D7). The jar is committed, so building the app needs no Android SDK;
# run this only after changing the helper's Java code.
#
#   scripts/build-android-helper.sh
#   ANDROID_HOME=/path/to/sdk scripts/build-android-helper.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PLATFORM="$(ls -d "$SDK"/platforms/android-* 2>/dev/null | sort -V | tail -n 1)"
BUILD_TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -n 1)"
[[ -f "$PLATFORM/android.jar" ]] || { echo "No android.jar under $SDK/platforms (set ANDROID_HOME)" >&2; exit 1; }
[[ -x "$BUILD_TOOLS/d8" ]] || { echo "No d8 under $SDK/build-tools (set ANDROID_HOME)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> javac ($(basename "$PLATFORM"))"
javac --release 11 -Xlint:-options -encoding UTF-8 -cp "$PLATFORM/android.jar" -d "$WORK/classes" \
  $(find android/clipboard-helper/src -name '*.java')

echo "==> d8 ($(basename "$BUILD_TOOLS"))"
(cd "$WORK/classes" && jar cf "$WORK/classes.jar" .)
"$BUILD_TOOLS/d8" --release --min-api 29 --lib "$PLATFORM/android.jar" --output "$WORK/dex.zip" "$WORK/classes.jar"

# Fixed timestamps, so the same source gives the same jar (its hash is part of the file name on the phone).
mkdir -p "$WORK/out"
(cd "$WORK/out" && unzip -q "$WORK/dex.zip" classes.dex && touch -t 202601010000 classes.dex \
  && rm -f "$ROOT/Resources/ukm-clipboard.jar" && zip -q -X "$ROOT/Resources/ukm-clipboard.jar" classes.dex)
echo "==> Built Resources/ukm-clipboard.jar ($(wc -c < Resources/ukm-clipboard.jar | tr -d ' ') bytes)"
