#!/bin/bash
# Builds the app, restarts it and streams its log.
#   scripts/run.sh                 # normal start
#   scripts/run.sh --ble-demo      # BLE demo mode (see README)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
pkill -x UniversalKM 2>/dev/null || true
open -n build/UniversalKM.app --args "$@"
echo "==> Log (Ctrl+C to stop watching; the app keeps running)"
exec log stream --level debug --style compact --predicate 'subsystem == "com.universalkm.UniversalKM"'
