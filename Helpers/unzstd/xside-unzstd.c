// xside-unzstd <in> <out> <maxBytes>: decompresses a zstd file (one or several frames) into <out>.
// Exit 0 done, 2 when the output would exceed <maxBytes> (output deleted), 1 any other error
// (output deleted). Files only; nothing is read from or written to anything else.
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "zstd.h"

static int fail(int code, const char *out, FILE *in, FILE *o, void *a, void *b, ZSTD_DCtx *ctx, const char *msg) {
    if (msg) fprintf(stderr, "xside-unzstd: %s\n", msg);
    if (in) fclose(in);
    if (o) fclose(o);
    unlink(out);
    free(a); free(b);
    ZSTD_freeDCtx(ctx);
    return code;
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: xside-unzstd <in> <out> <maxBytes>\n"); return 1; }
    char *end = NULL;
    errno = 0;
    unsigned long long max = strtoull(argv[3], &end, 10);
    if (errno || end == argv[3] || *end || argv[3][0] == '-') { fprintf(stderr, "xside-unzstd: bad maxBytes\n"); return 1; }
    FILE *in = fopen(argv[1], "rb");
    if (!in) { fprintf(stderr, "xside-unzstd: cannot open input\n"); return 1; }
    FILE *o = fopen(argv[2], "wb");
    if (!o) { fclose(in); fprintf(stderr, "xside-unzstd: cannot create output\n"); return 1; }
    size_t inCap = ZSTD_DStreamInSize(), outCap = ZSTD_DStreamOutSize();
    void *inBuf = malloc(inCap), *outBuf = malloc(outCap);
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    if (!inBuf || !outBuf || !ctx) return fail(1, argv[2], in, o, inBuf, outBuf, ctx, "out of memory");
    unsigned long long total = 0;
    size_t lastRet = 0;
    int sawInput = 0;
    size_t n;
    while ((n = fread(inBuf, 1, inCap, in)) > 0) {
        sawInput = 1;
        ZSTD_inBuffer ib = { inBuf, n, 0 };
        while (ib.pos < ib.size) {
            ZSTD_outBuffer ob = { outBuf, outCap, 0 };
            lastRet = ZSTD_decompressStream(ctx, &ob, &ib);
            if (ZSTD_isError(lastRet)) return fail(1, argv[2], in, o, inBuf, outBuf, ctx, ZSTD_getErrorName(lastRet));
            if (ob.pos > max - total) return fail(2, argv[2], in, o, inBuf, outBuf, ctx, "output over the cap");
            total += ob.pos;
            if (ob.pos && fwrite(outBuf, 1, ob.pos, o) != ob.pos) return fail(1, argv[2], in, o, inBuf, outBuf, ctx, "write error");
        }
    }
    if (ferror(in)) return fail(1, argv[2], in, o, inBuf, outBuf, ctx, "read error");
    // lastRet != 0: the last frame is cut short.
    if (!sawInput || lastRet != 0) return fail(1, argv[2], in, o, inBuf, outBuf, ctx, "truncated or empty input");
    if (fclose(o) != 0) { o = NULL; return fail(1, argv[2], in, NULL, inBuf, outBuf, ctx, "write error"); }
    fclose(in); free(inBuf); free(outBuf); ZSTD_freeDCtx(ctx);
    return 0;
}
