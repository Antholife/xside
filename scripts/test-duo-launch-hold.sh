#!/bin/bash
# Checks the iPhone Duo module's held notification callbacks (App/DuoLegacy/XSLaunchHoldCore.m,
# re-review N1) on the Mac: which callbacks wait for the deferred launch, the replay in order and
# once, the capacity. The rest of App/DuoLegacy is UIKit and iOS-only (built by bundle.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=11.0 \
    -I App/DuoLegacy -framework Foundation \
    -o "$OUT/test-duo-launch-hold" scripts/test-duo-launch-hold.m App/DuoLegacy/XSLaunchHoldCore.m
"$OUT/test-duo-launch-hold"
