#!/bin/bash
# Builds, from the pinned facebook/zstd source (scripts/zstd.env):
#   build/zstd/xside-unzstd  the decompression-only helper bundled in the app (arm64 + x86_64)
#   build/zstd/zstd          the zstd CLI, for tests and the test kit only, never shipped
# bundle.sh calls this; it can also be run alone (it is what `swift test` looks for).
# Without the source (no network, no cache) it warns and exits 3: nothing is built.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/zstd.env
SRC="$(scripts/fetch-pinned.sh zstd "$ZSTD_REPO" "$ZSTD_COMMIT")" || exit $?
OUT=build/zstd
mkdir -p "$OUT"
FLAGS=(-O2 -Wall -Werror -DZSTD_NO_INLINE=0 -mmacosx-version-min=15.0 -I "$SRC/lib" -I "$SRC/lib/common")
# The helper: decoder only. ZSTD_DISABLE_ASM keeps one source list for both architectures.
ARCH_OUT=()
for ARCH in arm64 x86_64; do
    clang -arch "$ARCH" "${FLAGS[@]}" -DZSTD_DISABLE_ASM \
        "$SRC"/lib/common/*.c "$SRC"/lib/decompress/*.c Helpers/unzstd/xside-unzstd.c -o "$OUT/xside-unzstd.$ARCH"
    ARCH_OUT+=("$OUT/xside-unzstd.$ARCH")
done
lipo -create "${ARCH_OUT[@]}" -output "$OUT/xside-unzstd"
rm -f "${ARCH_OUT[@]}"
# The CLI (tests only): the whole library plus programs/, built for this Mac.
clang -O2 -w -DZSTD_DISABLE_ASM -I "$SRC/lib" -I "$SRC/lib/common" -I "$SRC/lib/compress" -I "$SRC/lib/decompress" -I "$SRC/lib/dictBuilder" -I "$SRC/programs" \
    "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c "$SRC"/lib/decompress/*.c "$SRC"/lib/dictBuilder/*.c "$SRC"/programs/*.c \
    -o "$OUT/zstd"
echo "$OUT/xside-unzstd"
