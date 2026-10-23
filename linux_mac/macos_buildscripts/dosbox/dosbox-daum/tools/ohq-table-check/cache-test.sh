#!/usr/bin/env bash
# cache-test.sh -- prove the interpolation-table cache serves the right table.
#
# The cache exists because DOSBox calls GFX_SetSize far more often than the
# geometry changes: one real 640x480 session produced 18 OpenGLHQ_Init calls
# alternating between two output sizes, each rebuilding 4 MB of geometry at
# ~9 ms.  The saving is easy; the risk is that a slot hands back a table built
# for a DIFFERENT geometry, which would show up as "the scaler looks a bit off"
# and never as a failure -- the same class of bug that made this directory
# necessary in the first place.
#
# So this does not test that the cache is fast.  It tests that every table it
# returns is byte-identical to a table freshly built for that geometry, and
# that it stops rebuilding once warm.
#
# It compiles the REAL code, sliced out of vendor/openglhq/openglhq.cpp at
# build time, rather than a copy kept alongside.  mine.c is a copy and has to
# be diffed by hand when the original changes; anything sliced cannot drift.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SRC=../../vendor/openglhq/openglhq.cpp
OUT="${TMPDIR:-/tmp}/ohq-cache-test"
mkdir -p "$OUT"

[[ -f "$SRC" ]] || { echo "cannot find $SRC"; exit 1; }

# The pure region, between explicit markers.  An earlier version keyed on the
# name of the first function in it and on the next horizontal-rule comment,
# which would have sliced silently wrong the first time either moved.  The
# slice is then checked for what it must contain -- an empty or truncated slice
# would otherwise compile to a test that passes without exercising anything.
awk '/cache-test slice begin/{on=1; next} /cache-test slice end/{exit} on' \
    "$SRC" > "$OUT/pure.inc"

[[ -s "$OUT/pure.inc" ]] || { echo "FAIL: empty slice -- markers missing from $SRC"; exit 1; }

for want in build_interp_data build_interp_texture ohq_table_cache intersect_any setinterp ohq_plan; do
  grep -q "$want" "$OUT/pure.inc" \
    || { echo "FAIL: slice is missing $want -- the markers in $SRC moved"; exit 1; }
done

cat > "$OUT/main.c" <<'EOF'
/* Host harness: real geometry and real cache, GL calls stubbed to nothing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdbool.h>

#define OHQ_RESOLUTION 16
#include "SDL_openglhq_table.h"

typedef unsigned int GLuint;

/* Only the fields the sliced region touches. */
static struct { int srcw, srch; GLuint texture[4]; } ohq;

/* GL, reduced to nothing.  The upload is not what is under test; which bytes
   reach it is.  Capture the pointer so the harness can inspect it. */
static const unsigned char *uploaded;
#define GL_TEXTURE2 0
#define GL_TEXTURE0 0
#define GL_TEXTURE_3D 0
#define GL_RGBA8 0
#define GL_RGBA 0
#define GL_UNSIGNED_BYTE 0
#define GL_TEXTURE_MAG_FILTER 0
#define GL_TEXTURE_MIN_FILTER 0
#define GL_TEXTURE_WRAP_S 0
#define GL_TEXTURE_WRAP_T 0
#define GL_TEXTURE_WRAP_R 0
#define GL_NEAREST 0
#define GL_CLAMP_TO_EDGE 0
#define ohq_ActiveTexture(u)      ((void)0)
#define glEnable(x)               ((void)0)
#define glDisable(x)              ((void)0)
#define glBindTexture(t,n)        ((void)0)
#define glTexParameteri(a,b,c)    ((void)0)
#define ohq_TexImage3D(t,l,i,w,h,d,b,f,y,p) (uploaded = (const unsigned char *)(p))

#include "pure.inc"

/* Reference: build straight into a private buffer, bypassing the cache. */
static unsigned char *reference(int srcw, int srch, int outw, int outh)
{
    unsigned char *p = (unsigned char *)malloc(OHQ_TABLE_BYTES);
    if (!p) { perror("malloc"); exit(1); }
    build_interp_data(srcw, srch, outw, outh, p);
    return p;
}

static int fails;
static void check(int cond, const char *what)
{
    printf("  %-58s %s\n", what, cond ? "ok" : "FAIL");
    if (!cond) fails++;
}

int main(void)
{
    /* The two geometries the real session alternated between. */
    const int SRCW = 640, SRCH = 480;
    const int AW = 1280, AH = 960;
    const int BW = 1067, BH = 960;
    const int CW = 1600, CH = 1200;          /* a third, to force eviction */
    unsigned char *refA, *refB, *refC;
    int i, rebuilt_in_steady_state = 0;

    refA = reference(SRCW, SRCH, AW, AH);
    refB = reference(SRCW, SRCH, BW, BH);
    refC = reference(SRCW, SRCH, CW, CH);

    ohq.srcw = SRCW; ohq.srch = SRCH;

    printf("cold:\n");
    if (!build_interp_texture(AW, AH)) { printf("  build failed\n"); return 1; }
    check(memcmp(uploaded, refA, OHQ_TABLE_BYTES) == 0, "first A uploads a correct table");
    check(!ohq_last_table_cached, "first A is a rebuild");
    if (!build_interp_texture(BW, BH)) { printf("  build failed\n"); return 1; }
    check(memcmp(uploaded, refB, OHQ_TABLE_BYTES) == 0, "first B uploads a correct table");
    check(!ohq_last_table_cached, "first B is a rebuild");

    printf("the observed A/B/A/B session, 18 calls:\n");
    for (i = 0; i < 18; i++) {
        int w = (i & 1) ? BW : AW, h = (i & 1) ? BH : AH;
        const unsigned char *want = (i & 1) ? refB : refA;
        if (!build_interp_texture(w, h)) { printf("  build failed\n"); return 1; }
        if (memcmp(uploaded, want, OHQ_TABLE_BYTES) != 0) {
            printf("  call %d (%dx%d) uploaded the WRONG table%38s\n", i, w, h, "FAIL");
            fails++;
            break;
        }
        if (!ohq_last_table_cached) rebuilt_in_steady_state++;
    }
    check(fails == 0, "all 18 uploads are byte-identical to a fresh build");
    check(rebuilt_in_steady_state == 0, "none of the 18 rebuilt the table");

    printf("eviction (three geometries, two slots):\n");
    build_interp_texture(CW, CH);            /* evicts the LRU of A/B */
    check(!ohq_last_table_cached, "the third geometry is a rebuild");
    check(memcmp(uploaded, refC, OHQ_TABLE_BYTES) == 0, "C uploads a correct table");
    /* Whatever was evicted must come back CORRECT, not stale. */
    build_interp_texture(AW, AH);
    check(memcmp(uploaded, refA, OHQ_TABLE_BYTES) == 0, "A after eviction is still correct");
    build_interp_texture(BW, BH);
    check(memcmp(uploaded, refB, OHQ_TABLE_BYTES) == 0, "B after eviction is still correct");

    /* The teardown decision, enumerated.  Two of these three outcomes are
       destructive in opposite directions: REBUILD_FRESH when the context
       actually survived leaks every object; REBUILD_AFTER_DELETE when it did
       not deletes names that by then belong to DOSBox's own texture and
       display list. */
    printf("teardown plan:\n");
    {
        struct { bool ctx, act; int hw,hh,ow,oh, sw,sh,nw,nh; ohq_plan_t want; const char *what; } t[] = {
          {true , true , 640,480,1280,960, 640,480,1280,960, OHQ_REUSE,
           "context alive, everything identical -> reuse"},
          /* One field at a time.  A case that changes two at once passes even
             when the condition has dropped one of them -- which is exactly how
             an earlier version of this table let a mutation through. */
          {true , true , 640,480,1280,960, 641,480,1280,960, OHQ_REBUILD_AFTER_DELETE,
           "context alive, source WIDTH alone changed -> delete first"},
          {true , true , 640,480,1280,960, 640,481,1280,960, OHQ_REBUILD_AFTER_DELETE,
           "context alive, source HEIGHT alone changed -> delete first"},
          {true , true , 640,480,1280,960, 640,480,1067,960, OHQ_REBUILD_AFTER_DELETE,
           "context alive, output WIDTH alone changed -> delete first"},
          {true , true , 640,480,1280,960, 640,480,1280,961, OHQ_REBUILD_AFTER_DELETE,
           "context alive, output HEIGHT alone changed -> delete first"},
          {false, true , 640,480,1280,960, 640,480,1280,960, OHQ_REBUILD_FRESH,
           "context replaced -> do NOT delete stale names"},
          {false, false, 640,480,1280,960, 640,480,1280,960, OHQ_REBUILD_FRESH,
           "context replaced and inactive -> fresh"},
          {true , false, 640,480,1280,960, 640,480,1280,960, OHQ_REBUILD_AFTER_DELETE,
           "never initialised -> must not reuse nothing"},
        };
        size_t k;
        for (k = 0; k < sizeof(t)/sizeof(t[0]); k++)
            check(ohq_plan(t[k].ctx, t[k].act, t[k].hw,t[k].hh,t[k].ow,t[k].oh,
                           t[k].sw,t[k].sh,t[k].nw,t[k].nh) == t[k].want, t[k].what);
    }

    printf("negative control -- the check can fail:\n");
    check(memcmp(refA, refB, OHQ_TABLE_BYTES) != 0,
          "the two geometries really do produce different tables");

    printf("\n%s (%d failure%s)\n", fails ? "FAILED" : "passed", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
EOF

cp SDL_openglhq_table.h "$OUT/"
# gnu99, not c99: the sliced code uses clock_gettime, which strict ISO mode
# hides behind _POSIX_C_SOURCE on glibc.  It compiles either way on macOS,
# which is exactly the kind of difference that makes a tool "work on my
# machine" and fail everywhere else.
if ! cc -O2 -std=gnu99 -Wall -I"$OUT" -o "$OUT/cache-test" "$OUT/main.c" -lm; then
  echo
  echo "The slice did not compile.  Most likely the region between the markers in"
  echo "$SRC now reaches code that needs more than the stubs in this harness --"
  echo "check where 'cache-test slice end' sits."
  exit 1
fi
exec "$OUT/cache-test"
