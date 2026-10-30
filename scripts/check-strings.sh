#!/bin/bash
# Compares string keys across en/fr .strings and .stringsdict files; exits non-zero on mismatch or lint failure.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/App/Resources"
status=0
keys() { plutil -convert json -o - "$1" | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))'; }
for f in Localizable.strings ServicesMenu.strings Localizable.stringsdict; do
  en="$RES/en.lproj/$f"; fr="$RES/fr.lproj/$f"
  for p in "$en" "$fr"; do
    plutil -lint "$p" >/dev/null || { echo "lint failed: $p"; status=1; }
  done
  [ $status -eq 0 ] || continue
  missing_fr=$(comm -23 <(keys "$en") <(keys "$fr"))
  missing_en=$(comm -13 <(keys "$en") <(keys "$fr"))
  [ -n "$missing_fr" ] && { echo "Missing in fr.lproj/$f:"; echo "$missing_fr" | sed 's/^/  /'; status=1; }
  [ -n "$missing_en" ] && { echo "Missing in en.lproj/$f:"; echo "$missing_en" | sed 's/^/  /'; status=1; }
done
[ $status -eq 0 ] && echo "OK: en/fr strings match"
exit $status
