#!/bin/bash
# Checks scripts/changelog-html.py (Sparkle's update window) on a small CHANGELOG: a version's
# section, followed by the never-released sections it includes, stops at the next released one.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/scripts/changelog-html.py"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cat > "$OUT/CHANGELOG.md" <<'MD'
# Changelog

## [1.2.0-beta] - 2026-11-20

### Added
- **New in 1.2.**

## [1.1.0] — never released, included in 1.2.0

Never published as a version of its own.

### Added
- **New in 1.1.**

## [1.0.6-beta] - 2026-11-06

### Fixed
- Old fix.

[1.2.0-beta]: https://example.com
MD
fail() { echo "FAIL: $1" >&2; echo "$HTML" >&2; exit 1; }
HTML="$(cd "$OUT" && python3 -I "$SCRIPT" 1.2.0-beta)"
grep -q 'New in 1.2' <<<"$HTML" || fail "1.2.0-beta's own items missing"
grep -q 'New in 1.1' <<<"$HTML" || fail "the never-released 1.1.0 items are missing"
grep -q '1.1.0' <<<"$HTML" || fail "the never-released section isn't named"
! grep -q 'Old fix' <<<"$HTML" || fail "a released version's items leaked in"
HTML="$(cd "$OUT" && python3 -I "$SCRIPT" 1.0.6-beta)"
grep -q 'Old fix' <<<"$HTML" || fail "the last section isn't read up to the link references"
! grep -q 'New in' <<<"$HTML" || fail "1.0.6-beta took newer items"
echo "changelog-html: OK"
