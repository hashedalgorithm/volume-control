#!/bin/bash
# Builds VolumeControlMicMix.driver (a CoreAudio AudioServerPlugIn bundle).
# This only compiles the bundle into this repo; it does NOT install it.
# See ../docs/install-micmix.md for the install/uninstall steps.
set -euo pipefail

cd "$(dirname "$0")"

BUNDLE="VolumeControlMicMix.driver"
OUT="$BUNDLE/Contents/MacOS/VolumeControlMicMix"

clang -arch arm64 -arch x86_64 \
    -fobjc-arc -dynamiclib \
    -framework CoreFoundation -framework CoreAudio \
    -o "$OUT" \
    src/VolumeControlMicMix.c

install_name_tool -id "@rpath/VolumeControlMicMix" "$OUT" 2>/dev/null || true

echo "Built $OUT"
file "$OUT"
