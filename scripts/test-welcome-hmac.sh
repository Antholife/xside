#!/bin/bash
# Checks the iOS library's channel frames (App/Welcome/XSChannelCore.m), settings merge
# (App/Welcome/XSSettingsCore.m) and run marker (App/Welcome/XSRunMarkerCore.m) against the Swift side: both files are compiled for the Mac with
# scripts/test-welcome-hmac.m and run on Tests/XSideCoreTests/Fixtures/channel-fixture.json.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=11.0 \
    -I App/Welcome -framework Foundation -framework Security \
    -o "$OUT/test-welcome-hmac" \
    scripts/test-welcome-hmac.m App/Welcome/XSChannelCore.m App/Welcome/XSSettingsCore.m App/Welcome/XSRunMarkerCore.m
"$OUT/test-welcome-hmac" Tests/XSideCoreTests/Fixtures/channel-fixture.json
