#!/bin/bash
# Quits any running VolumeControl.app via a proper Apple Event (so it
# deregisters its status item cleanly -- SIGKILL skips that and is what
# caused the popover-position flakiness during development), rebuilds, and
# relaunches.
set -euo pipefail
cd "$(dirname "$0")/.."

osascript -e 'tell application id "com.volumecontrol.app" to quit' >/dev/null 2>&1 || true
sleep 1

./Scripts/make_app_bundle.sh "${1:-debug}"
open "$HOME/Applications/VolumeControl.app"
