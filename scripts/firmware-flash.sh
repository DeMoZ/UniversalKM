#!/bin/bash
# Flashes a ChameleonUltra over USB with the stock DFU bootloader (design D16).
#
#   scripts/firmware-flash.sh                  # build/ultra-dfu-app.zip (scripts/firmware-build.sh)
#   scripts/firmware-flash.sh path/to/app.zip  # any application DFU package
#   scripts/firmware-flash.sh --official       # roll back: official ultra-dfu-app.zip of $OFFICIAL_TAG
#   scripts/firmware-flash.sh --official v2.3.0
#
# Only the application is replaced: the bootloader and SoftDevice stay, so the device can always go back
# to DFU and be flashed again. The script asks the running firmware to enter DFU (the same frame as
# upstream resource/tools/enter_dfu.py). If that does not work: switch the Chameleon off, hold button B
# and plug USB in — LEDs 4 and 5 blink in DFU mode. Close the official client and UniversalKM first:
# only one program can hold the serial port.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# shellcheck source=../firmware/UPSTREAM
source "$ROOT/firmware/UPSTREAM"
TOOLS="${UKM_FIRMWARE_TOOLS:-$HOME/Library/Caches/UniversalKM-firmware-tools}"

PACKAGE="$ROOT/build/ultra-dfu-app.zip"
if [[ "${1:-}" == "--official" ]]; then
  tag="${2:-$OFFICIAL_TAG}"
  PACKAGE="$ROOT/build/official/$tag/ultra-dfu-app.zip"
  if [[ ! -f "$PACKAGE" ]]; then
    echo "==> Downloading the official $tag ultra-dfu-app.zip"
    mkdir -p "$(dirname "$PACKAGE")"
    curl -fsSL --retry 3 -o "$PACKAGE.download" \
      "https://github.com/RfidResearchGroup/ChameleonUltra/releases/download/$tag/ultra-dfu-app.zip"
    mv "$PACKAGE.download" "$PACKAGE"
  fi
elif [[ -n "${1:-}" ]]; then
  PACKAGE="$1"
fi
[[ -f "$PACKAGE" ]] || { echo "error: $PACKAGE not found (run scripts/firmware-build.sh)" >&2; exit 1; }

NRFUTIL="$(command -v nrfutil || true)"
[[ -n "$NRFUTIL" ]] || NRFUTIL="$TOOLS/bin/nrfutil"
[[ -x "$NRFUTIL" ]] || { echo "error: nrfutil not found (scripts/firmware-build.sh installs it)" >&2; exit 1; }

# USB IDs: application 6868:8686, DFU bootloader 1915:521f (decimal for ioreg).
usb_present() {
  ioreg -p IOUSB -l -w0 | awk -v vid="$1" -v pid="$2" '
    /\+-o / { v = 0; p = 0 }
    $0 ~ "\"idVendor\" = " vid "$"  { v = 1 }
    $0 ~ "\"idProduct\" = " pid "$" { p = 1 }
    v && p { found = 1 }
    END { exit !found }'
}
in_dfu() { usb_present 6421 21023; }
in_app() { usb_present 26728 34438; }

if ! in_dfu; then
  if in_app; then
    port="$(ls /dev/cu.usbmodem* 2>/dev/null | head -n 1 || true)"
    [[ -n "$port" ]] || { echo "error: ChameleonUltra is on USB, but its serial port is missing" >&2; exit 1; }
    echo "==> Asking the firmware on $port to enter DFU"
    # netdata frame DATA_CMD_ENTER_BOOTLOADER (1010), no data — as upstream enter_dfu.py.
    # Opening the port raises DTR, which the firmware needs to accept data.
    python3 -I -c '
import os, sys, termios, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
attrs = termios.tcgetattr(fd)
attrs[0] = 0; attrs[1] = 0; attrs[3] = 0
attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
attrs[4] = attrs[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, attrs)
os.write(fd, bytes([0x11, 0xEF, 0x03, 0xF2, 0x00, 0x00, 0x00, 0x00, 0x0B, 0x00]))
time.sleep(0.2)
os.close(fd)
' "$port"
  else
    echo "ChameleonUltra not found on USB."
  fi
  echo "==> Waiting for the DFU bootloader (1915:521f)…"
  echo "    If nothing happens: switch the Chameleon off, hold B and plug USB in (LEDs 4 and 5 blink)."
  for _ in $(seq 1 120); do
    in_dfu && break
    sleep 1
  done
  in_dfu || { echo "error: no DFU device after 2 minutes" >&2; exit 1; }
fi

echo "==> Flashing $(basename "$PACKAGE")"
"$NRFUTIL" device program --firmware "$PACKAGE" --traits nordicDfu

echo "==> Waiting for the Chameleon to restart…"
for _ in $(seq 1 30); do
  in_app && { echo "Done: ChameleonUltra is back on USB."; exit 0; }
  sleep 1
done
echo "warning: the Chameleon did not come back on USB within 30 s" >&2
exit 1
