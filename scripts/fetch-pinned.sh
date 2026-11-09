#!/bin/bash
# Usage: scripts/fetch-pinned.sh <name> <repo-url> <commit>
# Shared by every third-party source build (zstd, ElleKit, ...). Clones into build/<name>-src,
# fetches only when the pinned commit is missing, and stops unless HEAD is exactly the pin.
# No network and no cache: prints "warning: no <name> source" and exits 3 (the caller skips the
# component; release.sh then refuses to release).
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?usage: fetch-pinned.sh <name> <repo> <commit>}"
REPO="${2:?repo}"
COMMIT="${3:?commit}"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: $NAME pin '$COMMIT' is not a full commit SHA" >&2; exit 1; }
DIR="build/$NAME-src"
mkdir -p build
[ -d "$DIR/.git" ] || { rm -rf "$DIR"; git init -q "$DIR"; git -C "$DIR" remote add origin "$REPO"; }
if ! git -C "$DIR" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    if ! git -C "$DIR" fetch -q --depth 1 origin "$COMMIT" 2>/dev/null; then
        echo "warning: no $NAME source (not cached, and $REPO is unreachable)" >&2
        exit 3
    fi
fi
git -C "$DIR" checkout -q --detach "$COMMIT"
# A cache that was edited or has extra files is never built.
git -C "$DIR" reset -q --hard "$COMMIT"
git -C "$DIR" clean -q -ffdx
[ "$(git -C "$DIR" rev-parse HEAD)" = "$COMMIT" ] || { echo "error: $NAME source is not at $COMMIT" >&2; exit 1; }
echo "$DIR"
