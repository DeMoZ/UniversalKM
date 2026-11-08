#!/bin/bash
# Builds the ChameleonUltra DFU application package with the UniversalKM HID mode (design D15).
#
#   scripts/firmware-build.sh               # build/ultra-dfu-app.zip
#   scripts/firmware-build.sh --release     # + build/chameleon-ultra-hid-dfu-app-<app version>.zip (release.yml)
#   scripts/firmware-build.sh --upstream    # unmodified upstream, no HID mode (checks the toolchain)
#
# Steps: clone the upstream firmware at the commit pinned in firmware/UPSTREAM into build/firmware-src/,
# copy firmware/src/ into its application sources, apply firmware/patches/*.patch, build the application
# with the Arm GNU Toolchain and package it with nrfutil, signed with the upstream DFU key (the stock
# bootloader accepts it). Only the application is packaged: the bootloader and SoftDevice stay as they are.
#
# Tools are installed on first use into $UKM_FIRMWARE_TOOLS (default ~/Library/Caches/UniversalKM-firmware-tools):
# Arm GNU Toolchain 12.2.rel1 (the version upstream builds with; checked against Arm's SHA-256) and nrfutil
# with the nrf5sdk-tools and device commands. An arm-none-eabi-gcc / nrfutil already on PATH is used as is.
# Works on Apple Silicon Macs, including the macos-26 GitHub runner. No Docker.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# shellcheck source=../firmware/UPSTREAM
source "$ROOT/firmware/UPSTREAM"

MODE=hid
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    --upstream) MODE=upstream ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

SRC="$ROOT/build/firmware-src"
TOOLS="${UKM_FIRMWARE_TOOLS:-$HOME/Library/Caches/UniversalKM-firmware-tools}"

ARM_VERSION=12.2.rel1
ARM_NAME="arm-gnu-toolchain-$ARM_VERSION-darwin-arm64-arm-none-eabi"
ARM_URL="https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/$ARM_VERSION/binrel/$ARM_NAME.tar.xz"
ARM_SHA256=21a9e875250bcb0db8df4cb23dd43c94c00a1d3b98ecba9cdd6ed51586b12248
NRFUTIL_URL="https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/universal-apple-darwin/nrfutil"

# Must match upstream firmware/build.sh.
HW_VERSION=0            # ultra
SD_REQ=0x0100           # S140 7.2.0
APPLICATION_VERSION=1

# --- Tools -------------------------------------------------------------------

install_toolchain() {
  if command -v arm-none-eabi-gcc >/dev/null; then
    GNU_INSTALL_ROOT="$(dirname "$(command -v arm-none-eabi-gcc)")/"
    return
  fi
  GNU_INSTALL_ROOT="$TOOLS/$ARM_NAME/bin/"
  [[ -x "${GNU_INSTALL_ROOT}arm-none-eabi-gcc" ]] && return

  echo "==> Installing Arm GNU Toolchain $ARM_VERSION into $TOOLS"
  mkdir -p "$TOOLS"
  local download
  download="$(mktemp -d "$TOOLS/download.XXXXXX")"
  curl -fsSL --retry 3 -o "$download/$ARM_NAME.tar.xz" "$ARM_URL"
  local actual
  actual="$(shasum -a 256 "$download/$ARM_NAME.tar.xz" | cut -d' ' -f1)"
  if [[ "$actual" != "$ARM_SHA256" ]]; then
    echo "error: $ARM_NAME.tar.xz SHA-256 mismatch ($actual)" >&2
    rm -rf "$download"
    exit 1
  fi
  tar -xJf "$download/$ARM_NAME.tar.xz" -C "$TOOLS"
  rm -rf "$download"
  # The archive is not notarized; files fetched by curl carry no quarantine flag, but clear it just in case.
  xattr -dr com.apple.quarantine "$TOOLS/$ARM_NAME" 2>/dev/null || true
}

install_nrfutil() {
  if command -v nrfutil >/dev/null; then
    NRFUTIL="$(command -v nrfutil)"
  else
    NRFUTIL="$TOOLS/bin/nrfutil"
    if [[ ! -x "$NRFUTIL" ]]; then
      echo "==> Installing nrfutil into $TOOLS/bin"
      mkdir -p "$TOOLS/bin"
      curl -fsSL --retry 3 -o "$NRFUTIL.download" "$NRFUTIL_URL"
      chmod 755 "$NRFUTIL.download"
      mv "$NRFUTIL.download" "$NRFUTIL"
    fi
  fi
  # nrf5sdk-tools packages the DFU zip; device flashes it (scripts/firmware-flash.sh).
  local installed
  installed="$("$NRFUTIL" list 2>/dev/null || true)"
  for command in nrf5sdk-tools device; do
    if ! grep -q "^$command " <<<"$installed"; then
      echo "==> nrfutil install $command"
      "$NRFUTIL" install "$command"
    fi
  done
}

# --- Sources -----------------------------------------------------------------

fetch_upstream() {
  if [[ ! -d "$SRC/.git" ]]; then
    echo "==> Cloning $UPSTREAM_URL"
    rm -rf "$SRC"
    git clone --quiet --filter=blob:none "$UPSTREAM_URL" "$SRC"
  fi
  if ! git -C "$SRC" cat-file -e "$UPSTREAM_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --quiet --tags origin
  fi
  # build/firmware-src is generated: drop earlier patches and build output.
  git -C "$SRC" checkout --quiet --force --detach "$UPSTREAM_COMMIT"
  git -C "$SRC" clean -fdxq
  # The firmware version comes from `git describe --tags` (upstream Makefile).
  git -C "$SRC" describe --tags --match "v*.*" >/dev/null 2>&1 || git -C "$SRC" fetch --quiet --tags origin
  echo "==> Upstream $(git -C "$SRC" describe --tags --always --match "v*.*") ($UPSTREAM_COMMIT)"
}

apply_hid_mode() {
  if [[ -d "$ROOT/firmware/src" ]]; then
    echo "==> Copying firmware/src into the application sources"
    cp "$ROOT"/firmware/src/* "$SRC/firmware/application/src/"
  fi
  local patches=("$ROOT"/firmware/patches/*.patch)
  [[ -e "${patches[0]}" ]] || return 0
  for patch in "${patches[@]}"; do
    echo "==> git apply $(basename "$patch")"
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
  done
}

# --- Build -------------------------------------------------------------------

install_toolchain
install_nrfutil
fetch_upstream
[[ "$MODE" == hid ]] && apply_hid_mode

echo "==> Building the application (CURRENT_DEVICE_TYPE=ultra)"
make -C "$SRC/firmware/application" -j"$(sysctl -n hw.ncpu)" \
  CURRENT_DEVICE_TYPE=ultra GNU_INSTALL_ROOT="$GNU_INSTALL_ROOT" GNU_VERSION="${ARM_VERSION%.rel*}"

OBJECTS="$SRC/firmware/objects"
OUT="$ROOT/build/ultra-dfu-app.zip"
echo "==> Packaging $OUT"
rm -f "$OUT"
"$NRFUTIL" nrf5sdk-tools pkg generate \
  --hw-version "$HW_VERSION" \
  --key-file "$SRC/resource/dfu_key/chameleon.pem" \
  --application "$OBJECTS/application.hex" --application-version "$APPLICATION_VERSION" \
  --sd-req "$SD_REQ" \
  "$OUT"

if [[ "$RELEASE" == 1 ]]; then
  version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
  cp "$OUT" "$ROOT/build/chameleon-ultra-hid-dfu-app-$version.zip"
  echo "==> build/chameleon-ultra-hid-dfu-app-$version.zip"
fi
echo "Done: $OUT"
