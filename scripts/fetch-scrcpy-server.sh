#!/bin/bash
# Downloads scrcpy-server (Genymobile/scrcpy, Apache-2.0) into Resources/scrcpy-server.jar and checks its SHA-256
# (openspec/changes/add-android-screen-mirror, design D1). The version must match ScreenMirror.serverVersion in
# Sources/UniversalKMCore/ScreenMirror.swift: the server refuses a client of another version.
set -euo pipefail
VERSION=5.0.1
SHA256=764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/scrcpy-server.jar"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/server" "https://github.com/Genymobile/scrcpy/releases/download/v$VERSION/scrcpy-server-v$VERSION"
GOT="$(shasum -a 256 "$TMP/server" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
    echo "SHA-256 mismatch: got $GOT, want $SHA256" >&2
    exit 1
fi
mv "$TMP/server" "$OUT"
echo "scrcpy-server v$VERSION -> $OUT"
