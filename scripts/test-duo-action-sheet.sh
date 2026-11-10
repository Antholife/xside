#!/bin/bash
# Checks the iPhone Duo module's UIActionSheet stand-in bookkeeping (App/DuoLegacy/XSActionSheetCore.m)
# on the Mac: button indexes in UIActionSheet's order, cancel and destructive kinds, one dismissal per
# showing, where the popover points. The sheet itself is UIKit and iOS-only (built by bundle.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=11.0 \
    -I App/DuoLegacy -framework Foundation -framework CoreGraphics \
    -o "$OUT/test-duo-action-sheet" scripts/test-duo-action-sheet.m App/DuoLegacy/XSActionSheetCore.m
"$OUT/test-duo-action-sheet"
