/* openglhq.cpp -- OpenGL-HQ scaler for DOSBox.  See openglhq.h for the design
 * notes and provenance.  The geometry in the "interpolation table" section is
 * ported verbatim from SDL_ohqthread.h; everything else is new code that
 * replaces the SDL 1.2 driver plumbing.
 */
#include "dosbox.h"

#if C_OPENGL

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include <time.h>

#include "SDL.h"
#include "SDL_opengl.h"
#include "openglhq.h"

#include "SDL_openglhq_pass1.h"
#include "SDL_openglhq_pass2.h"
#include "SDL_openglhq_pass3.h"
#include "SDL_openglhq_table.h"

/* ------------------------------------------------------------------ *
 * Entry points we resolve ourselves.
 *
 * SDL_opengl.h declares the 1.1 core only; ARB_fragment_program and
 * EXT_framebuffer_object come in through SDL_GL_GetProcAddress.  Names are
 * prefixed so they cannot collide with anything sdlmain.cpp already pulled in.
 * ------------------------------------------------------------------ */
#ifndef GL_FRAGMENT_PROGRAM_ARB
#define GL_FRAGMENT_PROGRAM_ARB           0x8804
#define GL_PROGRAM_FORMAT_ASCII_ARB       0x8875
#define GL_PROGRAM_ERROR_POSITION_ARB     0x864B
#define GL_PROGRAM_ERROR_STRING_ARB       0x8874
#endif
#ifndef GL_FRAMEBUFFER_EXT
#define GL_FRAMEBUFFER_EXT                0x8D40
#define GL_COLOR_ATTACHMENT0_EXT          0x8CE0
#define GL_FRAMEBUFFER_COMPLETE_EXT       0x8CD5
#endif
#ifndef GL_TEXTURE0
#define GL_TEXTURE0                       0x84C0
#define GL_TEXTURE1                       0x84C1
#define GL_TEXTURE2                       0x84C2
#endif
#ifndef GL_TEXTURE_3D
#define GL_TEXTURE_3D                     0x806F
#define GL_TEXTURE_WRAP_R                 0x8072
#endif
#ifndef GL_CLAMP_TO_EDGE
#define GL_CLAMP_TO_EDGE                  0x812F
#endif
#ifndef GL_BGRA
#define GL_BGRA                           0x80E1
#endif

typedef void (APIENTRYP OHQ_PFNGENPROGRAMSARB)(GLsizei, GLuint *);
typedef void (APIENTRYP OHQ_PFNBINDPROGRAMARB)(GLenum, GLuint);
typedef void (APIENTRYP OHQ_PFNDELETEPROGRAMSARB)(GLsizei, const GLuint *);
typedef void (APIENTRYP OHQ_PFNPROGRAMSTRINGARB)(GLenum, GLenum, GLsizei, const void *);
typedef void (APIENTRYP OHQ_PFNPROGRAMENVPARAM4DARB)(GLenum, GLuint, GLdouble, GLdouble, GLdouble, GLdouble);
typedef void (APIENTRYP OHQ_PFNPROGRAMLOCALPARAM4DARB)(GLenum, GLuint, GLdouble, GLdouble, GLdouble, GLdouble);
typedef void (APIENTRYP OHQ_PFNGENFRAMEBUFFERSEXT)(GLsizei, GLuint *);
typedef void (APIENTRYP OHQ_PFNBINDFRAMEBUFFEREXT)(GLenum, GLuint);
typedef void (APIENTRYP OHQ_PFNDELETEFRAMEBUFFERSEXT)(GLsizei, const GLuint *);
typedef void (APIENTRYP OHQ_PFNFRAMEBUFFERTEXTURE2DEXT)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum (APIENTRYP OHQ_PFNCHECKFRAMEBUFFERSTATUSEXT)(GLenum);
typedef void (APIENTRYP OHQ_PFNACTIVETEXTURE)(GLenum);
typedef void (APIENTRYP OHQ_PFNTEXIMAGE3D)(GLenum, GLint, GLint, GLsizei, GLsizei,
                                           GLsizei, GLint, GLenum, GLenum, const void *);

static OHQ_PFNGENPROGRAMSARB            ohq_GenProgramsARB;
static OHQ_PFNBINDPROGRAMARB            ohq_BindProgramARB;
static OHQ_PFNDELETEPROGRAMSARB         ohq_DeleteProgramsARB;
static OHQ_PFNPROGRAMSTRINGARB          ohq_ProgramStringARB;
static OHQ_PFNPROGRAMENVPARAM4DARB      ohq_ProgramEnvParameter4dARB;
static OHQ_PFNPROGRAMLOCALPARAM4DARB    ohq_ProgramLocalParameter4dARB;
static OHQ_PFNGENFRAMEBUFFERSEXT        ohq_GenFramebuffersEXT;
static OHQ_PFNBINDFRAMEBUFFEREXT        ohq_BindFramebufferEXT;
static OHQ_PFNDELETEFRAMEBUFFERSEXT     ohq_DeleteFramebuffersEXT;
static OHQ_PFNFRAMEBUFFERTEXTURE2DEXT   ohq_FramebufferTexture2DEXT;
static OHQ_PFNCHECKFRAMEBUFFERSTATUSEXT ohq_CheckFramebufferStatusEXT;
static OHQ_PFNACTIVETEXTURE             ohq_ActiveTexture;
static OHQ_PFNTEXIMAGE3D                ohq_TexImage3D;

#define OHQ_RESOLUTION 16

static struct {
    bool   active;
    int    srcw, srch;
    int    outx, outy, outw, outh;   /* DOSBox's clip rectangle */
    int    texsize;
    GLfloat tex_w, tex_h;          /* used fraction of the source texture */
    GLuint texture[4];             /* src, pass1 out, pass2 out, 3D table  */
    GLuint fbo[2];
    GLuint program[3];
    int    static_threshold;       /* SDL_OPENGLHQ_STATIC,  default 10  */
    int    dynamic_threshold;      /* SDL_OPENGLHQ_DYNAMIC, default 33  */
    bool   render_probed;          /* first Render has been reported     */
} ohq;

bool OpenGLHQ_Active(void) { return ohq.active; }

/* ------------------------------------------------------------------ *
 * Probe -- evidence for verify-bundle.sh.
 *
 * The verifier used to decide whether openglhq initialised by grepping
 * DOSBox's stdout for the LOG_MSG at the end of OpenGLHQ_Init, and that could
 * not be made to work.  LOG_MSG goes through stdio, so a probe run that has to
 * be killed loses the whole buffer; and the only way to guarantee a flush was
 * to end the run with `-c exit`, which races the thing being measured --
 * GFX_SetSize runs from a PIC event, so quitting early means the mode set
 * never happens.  Every outcome collapsed to "saw nothing", which cannot
 * distinguish "openglhq did not start" from "openglhq started and the output
 * was discarded", so the check could only ever warn.
 *
 * The evidence therefore goes to a file named by SDL_OPENGLHQ_PROBE, opened
 * and closed around each line.  Nothing is ever left sitting in a buffer,
 * which makes SIGKILL a legitimate way to end the probe -- and that removes
 * the reason it had to exit early in the first place.
 *
 * Per-line open/close is far too slow for a hot path.  Nothing here is on one:
 * the calls sit on mode-set and first-frame paths, and the whole function
 * returns immediately when the variable is unset, which is every normal run.
 * ------------------------------------------------------------------ */
void OpenGLHQ_ProbeLog(const char *fmt, ...)
{
    const char *path = getenv("SDL_OPENGLHQ_PROBE");
    static bool started;
    FILE *f;
    va_list ap;

    if (!path || !*path) return;
    /* Truncate on this process's first write, append after.  Pure append across
     * runs looks harmless and is not: a second run leaves the previous run's
     * lines above its own, in whatever format that build emitted, and the file
     * reads as one long session.  That happened, and the stale half was read as
     * current before the format difference gave it away. */
    f = fopen(path, started ? "a" : "w");
    if (!f) return;
    started = true;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

/* ------------------------------------------------------------------ *
 * Interpolation table -- ported from SDL_ohqthread.h.
 *
 * The 4096-entry table classifies every combination of edges around a pixel.
 * These routines turn each entry into per-corner interpolation weights by
 * working out how much of the pixel falls inside the shape implied by that
 * edge pattern.  Result: a 256x16x256 RGBA texture the third pass indexes.
 * ------------------------------------------------------------------ */
/* Verbatim from SDL_ohqthread.h.  An earlier attempt reimplemented these from
 * their call sites and produced a table differing from upstream in 58% of its
 * bytes -- the geometry is subtle enough that it must be copied, not inferred.
 * Verified byte-identical against the original; see tools/ohq-table-check. */

/* ---8<--- cache-test slice begin ---8<--- */
/* The marker above is a complete comment on its own line, because the slice
 * starts at the NEXT line: opening a multi-line comment on the marker line
 * hands the harness an unterminated comment and a wall of syntax errors.
 *
 * Everything down to the matching end marker is pure enough to compile on the
 * host with the GL calls stubbed; tools/ohq-table-check/cache-test.sh slices
 * exactly this region and runs it.  Explicit markers rather than "starts at
 * sign()", because the previous version keyed on a function name and would
 * have silently sliced the wrong thing the first time anything moved. */

/* Microseconds, monotonic.  Used for the init breakdown, which is CPU-side
 * submission cost -- GL commands are asynchronous, so the GPU work behind a
 * texture upload is NOT included unless SDL_OPENGLHQ_TIME_SYNC=1 forces a
 * glFinish.  Submission cost is the number that matters by default: it is what
 * blocks DOSBox's main loop. */
static double ohq_now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e6 + (double)ts.tv_nsec / 1e3;
}

/* Filled in by OpenGLHQ_Init, reported on the probe line. */
static struct {
    double entry, tex, prog, fbo, table_build, table_upload, total;
    bool   synced;
} ohq_t;

static double sign(double a) {
    return (a < 0?-1:1);
}

/*
 This function calculates what percentage of a rectangle intersected by a line lies near the center of the
 cordinate system. It is mathematically exact, and well-tested for xcenter > 0 and ycenter > 0 (it's only
 used that way). It should be correct for other cases as well, but well... famous last words :)
*/
static double intersect_any(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double g = fabs(gradient)*xsize/ysize;
    double o = -((yoffset-ycenter) + gradient*xcenter)/ysize*sign(ycenter)*sign(yoffset)-g*0.5+0.5;
    double yl = o, yr = o+g, xb = -o/g, xt = (1-o)/g;
    double area = 1.0;

    if (yl >= 1.0) xt = xb = area = 0.0;
    else if (yl > 0.0) {
        area = 1.0-yl;
        xb = 0.0;
    }
    else if (yr <= 0.0) yl = yr = area = 1.0;
    else yl = o+xb*g;

    if (xt <= 0.0) yr = yl = area = 0.0;
    else if (xt < 1.0) {
        area *= xt;
        yr = 1.0;
    }
    else if (xb >= 1.0) xb = xt = area = 1.0;
    else xt = (yr-o)/g;

    area -= (xt-xb)*(yr-yl)/2;

    return area;
}

static double intersect_h(double xcenter, double ycenter, double xsize, double ysize) {
    return fmax(0.0,fmin(1.0,(.55-fabs(xcenter)+xsize/2.0)/xsize));
    //return fmax(0.0,fmin(1.0,(.50-fabs(xcenter)+xsize/2.0)/xsize));
}

static double intersect_any_h(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double hinside = intersect_h(xcenter,ycenter,xsize,ysize);
    return hinside*hinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_v(double xcenter, double ycenter, double xsize, double ysize) {
    return fmax(0.0,fmin(1.0,(.55-fabs(ycenter)+ysize/2.0)/ysize));
    //return fmax(0.0,fmin(1.0,(.50-fabs(ycenter)+ysize/2.0)/ysize));
}

static double intersect_any_v(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double vinside = intersect_v(xcenter,ycenter,xsize,ysize);
    return vinside*vinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_hv(double xcenter, double ycenter, double xsize, double ysize) {
    double hinside = intersect_h(xcenter,ycenter,xsize,ysize);
    double vinside = intersect_v(xcenter,ycenter,xsize,ysize);
    return (1-hinside)*(1-vinside)+hinside*vinside;
}

/* FIXME: not sure if this is correct, but it is rare enough and most likely near enough. fixes welcome :) */
static double intersect_any_hv(double xcenter, double ycenter, double xsize, double ysize, double yoffset, double gradient) {
    double hvinside = intersect_hv(xcenter,ycenter,xsize,ysize);
    return hvinside*hvinside*intersect_any(xcenter,ycenter,xsize,ysize,yoffset,gradient);
}

static double intersect_hvd(double xcenter, double ycenter, double xsize, double ysize) {
    return intersect_h(xcenter,ycenter,xsize,ysize)*intersect_v(xcenter,ycenter,xsize,ysize);
}

static void setinterp(double xcenter, double ycenter, double percentage_inside, int i1, int i2, int i3, int o1, int o2, int o3, unsigned char *factors) {
    double d0, d1, d2, d3, percentage_outside, totaldistance_i, totaldistance_o;
    xcenter = fabs(xcenter);
    ycenter = fabs(ycenter);
    d0 = (1-xcenter)*(1-ycenter);
    d1 = xcenter*(1-ycenter);
    d2 = (1-xcenter)*ycenter;
    d3 = xcenter*ycenter;
    if (i1 && i2) i3 = 0;
    if (o1 && o2) o3 = 0;
    percentage_outside = 1.0-percentage_inside;
    totaldistance_i = d0+i1*d1+i2*d2+i3*d3;
    totaldistance_o = o1*d1+o2*d2+o3*d3+1e-12; /* +1e-12: prevent division by zero */

    factors[1] = (unsigned char)(((d1/totaldistance_i*percentage_inside*i1)+(d1/totaldistance_o*percentage_outside*o1))*255+.5);
    factors[2] = (unsigned char)(((d2/totaldistance_i*percentage_inside*i2)+(d2/totaldistance_o*percentage_outside*o2))*255+.5);
    factors[3] = (unsigned char)(((d3/totaldistance_i*percentage_inside*i3)+(d3/totaldistance_o*percentage_outside*o3))*255+.5);
    factors[0] = 255-factors[1]-factors[2]-factors[3];/*(unsigned char)((d0/totaldistance_i*percentage_inside)*255+.5);*/
}

/* Wanna have gcc fun? #define this as a macro, get a fast machine and go fetch a coffe or two. See how it is used to get an idea why.
   I aborted compilation after 5 minutes of CPU time on an Athlon64 3700+. */
static int swap_bits(int num, int bit1, int bit2) {
    return ((num & ~(bit1|bit2))|((num&bit1)?bit2:0)|((num&bit2)?bit1:0));
}

/* border bits */
#define OHQ_R 1
#define OHQ_T 2
#define OHQ_RT 4
#define OHQ_RT2 8
#define OHQ_L 16
#define OHQ_LB2 32
#define OHQ_LT2 64
#define OHQ_LT 128
#define OHQ_LB 256
#define OHQ_B 512
#define OHQ_RB2 1024
#define OHQ_RB 2048
#define OHQ_NODIAG 0x90
#define OHQ_H 1
#define OHQ_V 2
#define OHQ_D 4

#define ohq_hmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,OHQ_R,OHQ_L),OHQ_RT,OHQ_LT),OHQ_RT2,OHQ_LT2),OHQ_RB,OHQ_LB),OHQ_RB2,OHQ_LB2)
#define ohq_vmirror(p) swap_bits(swap_bits(swap_bits(swap_bits(swap_bits(p,OHQ_T,OHQ_B),OHQ_RT,OHQ_RB),OHQ_RT2,OHQ_RB2),OHQ_LT,OHQ_LB),OHQ_LT2,OHQ_LB2)
#define NO_BORDER(x) ((b & (x)) == 0)
#define IS_BORDER(x) ((b & (x)) == (x))

#define OHQ_TABLE_BYTES ((size_t)OHQ_RESOLUTION * OHQ_RESOLUTION * 4096 * 4)

/* The geometry pass, with no GL in it and no dependency on `ohq`.
 *
 * Split out from the upload so it can be cached: it is a pure function of the
 * four sizes below (only through their two ratios), it costs ~9 ms, and it is
 * the reason a re-init is expensive.  Everything else OpenGLHQ_Init does --
 * textures, programs, FBOs -- is cheap and MUST be redone, because GFX_SetSize
 * replaces the GL context underneath us.
 *
 * `dst` must hold OHQ_TABLE_BYTES (4 MB). */
static void build_interp_data(int srcw, int srch, int outw, int outh,
                              unsigned char *dst)
{
    unsigned char table[4096] = SDL_openglhq_table_dat;
    double xsize, ysize;
    int border, x, y;
    unsigned char *texture = dst;

    memset(texture, 0, OHQ_TABLE_BYTES);

    /* Scale ratio: this is why the table is not resize-invariant. */
    xsize = (double)srcw / (double)outw;
    ysize = (double)srch / (double)outh;

    for (border = 0; border < 4096; border++) {
        for (y = 0; y < OHQ_RESOLUTION; y++) {
            for (x = 0; x < OHQ_RESOLUTION; x++) {
                double xcenter = fabs((((double)x) + .5) / (double)OHQ_RESOLUTION - .5);
                double ycenter = fabs((((double)y) + .5) / (double)OHQ_RESOLUTION - .5);
                int sx = (x < OHQ_RESOLUTION / 2 ? -1 : 1);
                int sy = (y < OHQ_RESOLUTION / 2 ? -1 : 1);
                int b = (sy > 0 ? (sx > 0 ? border : ohq_hmirror(border))
                                : (sx > 0 ? ohq_vmirror(border)
                                          : ohq_vmirror(ohq_hmirror(border))));
                unsigned char *factors = texture +
                    ((x + (border % 16) * OHQ_RESOLUTION +
                      y * 16 * OHQ_RESOLUTION +
                      (border & ~15) * OHQ_RESOLUTION * OHQ_RESOLUTION) * 4);
                double pct;

                if ((table[b] & OHQ_NODIAG) == OHQ_NODIAG) {
                    if (table[b] & OHQ_H) {
                        if (table[b] & OHQ_V)
                            pct = (table[b] & OHQ_D) ? intersect_hvd(xcenter, ycenter, xsize, ysize)
                                                     : intersect_hv (xcenter, ycenter, xsize, ysize);
                        else
                            pct = intersect_h(xcenter, ycenter, xsize, ysize);
                    } else if (table[b] & OHQ_V) {
                        pct = intersect_v(xcenter, ycenter, xsize, ysize);
                    } else {
                        pct = 1.0;
                    }
                } else {
                    double yoff = (table[b] &  4 ? 1 : -1) * (((table[b] >> 3) & 3) + 1) / 4.0;
                    double grad = (table[b] & 32 ? 1 : -1) * (((table[b] >> 6) & 3) + 1) / 2.0;
                    if (table[b] & OHQ_H) {
                        pct = (table[b] & OHQ_V)
                            ? intersect_any_hv(xcenter, ycenter, xsize, ysize, yoff, grad)
                            : intersect_any_h (xcenter, ycenter, xsize, ysize, yoff, grad);
                    } else if (table[b] & OHQ_V) {
                        pct = intersect_any_v(xcenter, ycenter, xsize, ysize, yoff, grad);
                    } else {
                        pct = intersect_any(xcenter, ycenter, xsize, ysize, yoff, grad);
                    }
                }
                setinterp(xcenter, ycenter, pct,
                          NO_BORDER(OHQ_R), NO_BORDER(OHQ_T), NO_BORDER(OHQ_RT),
                          IS_BORDER(OHQ_R), IS_BORDER(OHQ_T), IS_BORDER(OHQ_RT),
                          factors);
            }
        }
    }
}

/* ------------------------------------------------------------------ *
 * Table cache.
 *
 * DOSBox calls GFX_SetSize far more often than the geometry changes.  One real
 * session -- a 640x480 game -- produced 18 calls, alternating between two
 * output sizes, 1067x960 and 1280x960.  Each call replaces the GL context, so
 * the 3D texture genuinely cannot be kept; but the 4 MB of geometry behind it
 * is a pure function of the four sizes and was being recomputed every time, at
 * ~9 ms a go (measured, see tools/ohq-table-check).
 *
 * Two entries, not one.  The measured sequence is not a strict alternation but
 * bursts -- AA BBBB AAAA BBBB AAAA -- so a single slot would have rebuilt at
 * each of the five transitions rather than at all eighteen calls.  Two slots
 * reach the floor: one rebuild per distinct geometry, 2 instead of 5, measured
 * at 13 and 16 ms on an M-series Mac.  8 MB, which for a scaler already
 * holding a 4 MB texture and three FBOs is not the expensive part.
 *
 * (The first version of this comment claimed a single slot would miss on every
 * call.  The probe output says otherwise; the justification was written before
 * the data and did not survive it.)
 *
 * Deliberately NOT freed by OpenGLHQ_Shutdown: surviving teardown is the whole
 * point, since teardown is exactly what happens between two re-inits.  It is
 * bounded, so it is released at process exit and never grows.
 * ------------------------------------------------------------------ */
#define OHQ_TABLE_CACHE 2
static struct {
    bool           valid;
    int            srcw, srch, outw, outh;
    unsigned long  used;              /* LRU stamp */
    unsigned char *data;
} ohq_table_cache[OHQ_TABLE_CACHE];
static unsigned long ohq_table_clock;

/* Set by the last build_interp_texture() so the caller can report which
 * happened without threading a return value through. */
static bool ohq_last_table_cached;

static bool build_interp_texture(int outw, int outh)
{
    unsigned char *texture = NULL;
    int i, slot = -1;

    ohq_last_table_cached = false;
    ohq_t.table_build = ohq_t.table_upload = 0;

    for (i = 0; i < OHQ_TABLE_CACHE; i++) {
        if (ohq_table_cache[i].valid &&
            ohq_table_cache[i].srcw == ohq.srcw && ohq_table_cache[i].srch == ohq.srch &&
            ohq_table_cache[i].outw == outw     && ohq_table_cache[i].outh == outh) {
            slot = i;
            ohq_last_table_cached = true;
            break;
        }
    }

    if (slot < 0) {
        /* Miss: take the least recently used slot, or the first free one. */
        slot = 0;
        for (i = 0; i < OHQ_TABLE_CACHE; i++) {
            if (!ohq_table_cache[i].valid) { slot = i; break; }
            if (ohq_table_cache[i].used < ohq_table_cache[slot].used) slot = i;
        }
        if (!ohq_table_cache[slot].data) {
            ohq_table_cache[slot].data = (unsigned char *)malloc(OHQ_TABLE_BYTES);
            if (!ohq_table_cache[slot].data) return false;
        }
        /* Invalidate, build, then publish the key.  The window this closes is
         * currently unreachable -- build_interp_data cannot fail and nothing
         * re-enters here -- so this is ordering by construction rather than a
         * fix for an observed bug, and tools/ohq-table-check/cache-test.sh
         * confirms it cannot tell the two orderings apart.  Kept because the
         * alternative publishes a key over bytes that do not match it yet, and
         * that failure would be silent. */
        ohq_table_cache[slot].valid = false;
        {
            double t0 = ohq_now_us();
            build_interp_data(ohq.srcw, ohq.srch, outw, outh, ohq_table_cache[slot].data);
            ohq_t.table_build = ohq_now_us() - t0;
        }
        ohq_table_cache[slot].srcw = ohq.srcw; ohq_table_cache[slot].srch = ohq.srch;
        ohq_table_cache[slot].outw = outw;     ohq_table_cache[slot].outh = outh;
        ohq_table_cache[slot].valid = true;
    }

    ohq_table_cache[slot].used = ++ohq_table_clock;
    texture = ohq_table_cache[slot].data;

    ohq_t.table_upload = ohq_now_us();
    ohq_ActiveTexture(GL_TEXTURE2);
    glEnable(GL_TEXTURE_3D);
    glBindTexture(GL_TEXTURE_3D, ohq.texture[3]);
    ohq_TexImage3D(GL_TEXTURE_3D, 0, GL_RGBA8, 16 * OHQ_RESOLUTION, OHQ_RESOLUTION, 256,
                   0, GL_RGBA, GL_UNSIGNED_BYTE, texture);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    /* A fragment program samples regardless of the fixed-function enable, and
     * leaving unit 2 enabled would modulate DOSBox's own glCallList output if
     * we ever fall back to it. */
    glDisable(GL_TEXTURE_3D);
    ohq_ActiveTexture(GL_TEXTURE0);
    ohq_t.table_upload = ohq_now_us() - ohq_t.table_upload;
    return true;
}

/* What Init has to do this time.
 *
 * Pulled out as a pure function so the off-device test can enumerate the cases
 * instead of re-typing the condition -- the decision is the part with teeth.
 * Getting REBUILD_FRESH wrong when the context survived leaks every object;
 * getting REBUILD_AFTER_DELETE wrong when it did not deletes names that now
 * belong to DOSBox's own texture and display list. */
typedef enum {
    OHQ_REUSE,                 /* context alive, geometry unchanged: keep it all */
    OHQ_REBUILD_AFTER_DELETE,  /* context alive, geometry changed: delete first  */
    OHQ_REBUILD_FRESH          /* context gone: the release already ran          */
} ohq_plan_t;

static ohq_plan_t ohq_plan(bool ctx_survived, bool active,
                           int have_srcw, int have_srch, int have_outw, int have_outh,
                           int srcw, int srch, int outw, int outh)
{
    if (ctx_survived && active &&
        have_srcw == srcw && have_srch == srch &&
        have_outw == outw && have_outh == outh)
        return OHQ_REUSE;
    return ctx_survived ? OHQ_REBUILD_AFTER_DELETE : OHQ_REBUILD_FRESH;
}

/* ---8<--- cache-test slice end ---8<--- */

/* ------------------------------------------------------------------ */

static bool resolve_entry_points(void)
{
#define GET(v, t, n) do { v = (t)SDL_GL_GetProcAddress(n); \
                          if (!v) { LOG_MSG("openglhq: missing %s", n); \
                                    OpenGLHQ_ProbeLog("fail entrypoint %s", n); \
                                    return false; } } while (0)
    GET(ohq_GenProgramsARB,            OHQ_PFNGENPROGRAMSARB,            "glGenProgramsARB");
    GET(ohq_BindProgramARB,            OHQ_PFNBINDPROGRAMARB,            "glBindProgramARB");
    GET(ohq_DeleteProgramsARB,         OHQ_PFNDELETEPROGRAMSARB,         "glDeleteProgramsARB");
    GET(ohq_ProgramStringARB,          OHQ_PFNPROGRAMSTRINGARB,          "glProgramStringARB");
    GET(ohq_ProgramEnvParameter4dARB,  OHQ_PFNPROGRAMENVPARAM4DARB,      "glProgramEnvParameter4dARB");
    GET(ohq_ProgramLocalParameter4dARB,OHQ_PFNPROGRAMLOCALPARAM4DARB,    "glProgramLocalParameter4dARB");
    GET(ohq_GenFramebuffersEXT,        OHQ_PFNGENFRAMEBUFFERSEXT,        "glGenFramebuffersEXT");
    GET(ohq_BindFramebufferEXT,        OHQ_PFNBINDFRAMEBUFFEREXT,        "glBindFramebufferEXT");
    GET(ohq_DeleteFramebuffersEXT,     OHQ_PFNDELETEFRAMEBUFFERSEXT,     "glDeleteFramebuffersEXT");
    GET(ohq_FramebufferTexture2DEXT,   OHQ_PFNFRAMEBUFFERTEXTURE2DEXT,   "glFramebufferTexture2DEXT");
    GET(ohq_CheckFramebufferStatusEXT, OHQ_PFNCHECKFRAMEBUFFERSTATUSEXT, "glCheckFramebufferStatusEXT");
    GET(ohq_ActiveTexture,             OHQ_PFNACTIVETEXTURE,             "glActiveTexture");
    GET(ohq_TexImage3D,                OHQ_PFNTEXIMAGE3D,                "glTexImage3D");
#undef GET
    return true;
}

static GLuint load_program(const char *src, const char *name)
{
    GLuint id = 0;
    GLint errpos = -1;
    ohq_GenProgramsARB(1, &id);
    ohq_BindProgramARB(GL_FRAGMENT_PROGRAM_ARB, id);
    ohq_ProgramStringARB(GL_FRAGMENT_PROGRAM_ARB, GL_PROGRAM_FORMAT_ASCII_ARB,
                         (GLsizei)strlen(src), src);
    glGetIntegerv(GL_PROGRAM_ERROR_POSITION_ARB, &errpos);
    if (errpos != -1) {
        const GLubyte *err = glGetString(GL_PROGRAM_ERROR_STRING_ARB);
        LOG_MSG("openglhq: %s failed to compile at offset %d: %s",
                name, (int)errpos, err ? (const char *)err : "?");
        OpenGLHQ_ProbeLog("fail program %s at %d: %s",
                          name, (int)errpos, err ? (const char *)err : "?");
        ohq_DeleteProgramsARB(1, &id);
        return 0;
    }
    return id;
}

static int int_log2(int val) { int r = 0; while (val >>= 1) r++; return r; }

/* Context tracking.
 *
 * SDL_SetVideoMode_Wrap has a SETMODE_SAVES short-circuit: when width, height,
 * bpp and flags are all unchanged it returns the existing surface WITHOUT
 * calling SDL_SetVideoMode, so the GL context and everything in it survives.
 * DOSBox re-runs GFX_SetSize far more often than anything changes -- a measured
 * session did it 18 times, of which 13 changed nothing -- and openglhq used to
 * tear everything down on every one of them.  Measured cost of one of those
 * needless rebuilds: ~1.9 ms, dominated by re-uploading the 4 MB table and
 * recompiling three fragment programs.
 *
 * WHERE the teardown happens is not a detail.  GL object names are only
 * meaningful inside the context that issued them; once a context is replaced,
 * name 7 may belong to something else entirely -- DOSBox creates its own
 * texture and display list in the new one.  Deleting stale names afterwards
 * would delete somebody else's objects.  So the release is driven from inside
 * SDL_SetVideoMode_Wrap, on the branch that is about to replace the context and
 * while the old one is still current.  That is the only moment where the answer
 * is both known and still actionable.
 *
 * The corollary is that no teardown is needed on the surviving path at all:
 * nothing was destroyed, so nothing has to be rebuilt. */
static unsigned long ohq_context_gen;
static unsigned long ohq_context_gen_at_init = (unsigned long)-1;

void OpenGLHQ_ReleaseForContextChange(void)
{
    /* Called with the OLD context still current.  Deleting here is valid;
     * deleting after SDL_SetVideoMode would not be. */
    OpenGLHQ_Shutdown();
    ohq_context_gen++;
}

bool OpenGLHQ_Init(int srcw, int srch, int outx, int outy, int outw, int outh)
{
    const char *env;
    int i;
    double t0, tmark;
    bool ctx_survived = (ohq_context_gen == ohq_context_gen_at_init);
    ohq_plan_t plan;

    t0 = tmark = ohq_now_us();
    memset(&ohq_t, 0, sizeof(ohq_t));

    plan = ohq_plan(ctx_survived, ohq.active,
                    ohq.srcw, ohq.srch, ohq.outw, ohq.outh,
                    srcw, srch, outw, outh);

    /* Nothing was destroyed and nothing changed: keep the lot.
     *
     * outx/outy are excluded from the comparison deliberately -- the clip
     * ORIGIN can move without the size changing (letterboxing), and pass 3
     * reads them per frame, so updating the two ints is the entire response. */
    if (plan == OHQ_REUSE) {
        ohq.outx = outx; ohq.outy = outy;
        ohq_t.total = ohq_now_us() - t0;
        OpenGLHQ_ProbeLog("init reuse %dx%d -> %dx%d at %d,%d, ctx SURVIVED, us: total=%.0f",
                          srcw, srch, outw, outh, outx, outy, ohq_t.total);
        return true;
    }

    /* Either the context went away -- in which case the release already ran and
     * there is nothing left to delete -- or it survived but the geometry
     * changed, and the objects are still live and must go now, while this
     * context is still the current one. */
    if (plan == OHQ_REBUILD_AFTER_DELETE) OpenGLHQ_Shutdown();
    memset(&ohq, 0, sizeof(ohq));
    ohq.srcw = srcw; ohq.srch = srch;
    ohq.outx = outx; ohq.outy = outy;
    ohq.outw = outw; ohq.outh = outh;

    /* Before anything that can fail, so "entered and died" is distinguishable
     * from "never called". */
    OpenGLHQ_ProbeLog("init enter %dx%d -> %dx%d at %d,%d",
                      srcw, srch, outw, outh, outx, outy);

    if (!resolve_entry_points()) return false;
    ohq_t.entry = ohq_now_us() - tmark; tmark = ohq_now_us();

    ohq.static_threshold = 10;
    ohq.dynamic_threshold = 33;
    if ((env = getenv("SDL_OPENGLHQ_STATIC"))  != NULL) ohq.static_threshold  = atoi(env);
    if ((env = getenv("SDL_OPENGLHQ_DYNAMIC")) != NULL) ohq.dynamic_threshold = atoi(env);
    if (ohq.static_threshold  > 255) ohq.static_threshold  = 255;
    if (ohq.static_threshold  <   0) ohq.static_threshold  = 0;
    if (ohq.dynamic_threshold > 100) ohq.dynamic_threshold = 100;
    if (ohq.dynamic_threshold <   0) ohq.dynamic_threshold = 0;

    ohq.texsize = 2 << int_log2(srcw > srch ? srcw : srch);
    ohq.tex_w = (GLfloat)srcw / (GLfloat)ohq.texsize;
    ohq.tex_h = (GLfloat)srch / (GLfloat)ohq.texsize;

    glGenTextures(4, ohq.texture);
    for (i = 0; i < 3; i++) {
        glBindTexture(GL_TEXTURE_2D, ohq.texture[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, ohq.texsize, ohq.texsize, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    }
    ohq_t.tex = ohq_now_us() - tmark; tmark = ohq_now_us();

    ohq.program[0] = load_program(SDL_openglhq_pass1_fp, "pass1");
    ohq.program[1] = load_program(SDL_openglhq_pass2_fp, "pass2");
    ohq.program[2] = load_program(SDL_openglhq_pass3_fp, "pass3");
    if (!ohq.program[0] || !ohq.program[1] || !ohq.program[2]) { OpenGLHQ_Shutdown(); return false; }
    ohq_t.prog = ohq_now_us() - tmark; tmark = ohq_now_us();

    ohq_GenFramebuffersEXT(2, ohq.fbo);
    for (i = 0; i < 2; i++) {
        ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, ohq.fbo[i]);
        ohq_FramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                                    GL_TEXTURE_2D, ohq.texture[i + 1], 0);
        if (ohq_CheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) != GL_FRAMEBUFFER_COMPLETE_EXT) {
            LOG_MSG("openglhq: framebuffer object %d incomplete", i);
            OpenGLHQ_ProbeLog("fail fbo %d incomplete", i);
            ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
            OpenGLHQ_Shutdown();
            return false;
        }
    }
    ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    ohq_t.fbo = ohq_now_us() - tmark;

    if (!build_interp_texture(outw, outh)) {
        OpenGLHQ_ProbeLog("fail interpolation table");
        OpenGLHQ_Shutdown();
        return false;
    }

    /* Env parameter 1 is constant for the life of the context (upstream's
     * "adjust" tuning knob, fixed at 1). */
    ohq_BindProgramARB(GL_FRAGMENT_PROGRAM_ARB, ohq.program[2]);
    ohq_ProgramEnvParameter4dARB(GL_FRAGMENT_PROGRAM_ARB, 1,
                                 1.0 / .875, -(1.0 / .875 - 1.0) / 2, .875, (1 - .875) / 2);

    ohq.active = true;
    ohq_context_gen_at_init = ohq_context_gen;

    /* GL is asynchronous, so by default these are submission costs, not the
     * GPU's work.  Submission is what stalls DOSBox's loop, so it is the right
     * default -- but set SDL_OPENGLHQ_TIME_SYNC=1 to drain the pipeline first
     * and get the true cost, at the price of a stall this code would not
     * otherwise cause.  Saying which is in the line itself, because a timing
     * number whose meaning has to be looked up gets misread. */
    ohq_t.synced = (getenv("SDL_OPENGLHQ_TIME_SYNC") != NULL);
    if (ohq_t.synced) glFinish();
    ohq_t.total = ohq_now_us() - t0;

    LOG_MSG("openglhq: %dx%d -> %dx%d, %d^2 textures, static=%d dynamic=%d, table %s, init %.1fms",
            srcw, srch, outw, outh, ohq.texsize,
            ohq.static_threshold, ohq.dynamic_threshold,
            ohq_last_table_cached ? "cached" : "rebuilt", ohq_t.total / 1000.0);
    OpenGLHQ_ProbeLog("init ok %dx%d -> %dx%d, %d^2 textures, static=%d dynamic=%d, table %s, "
                      "ctx %s, %s us: entry=%.0f tex=%.0f prog=%.0f fbo=%.0f build=%.0f upload=%.0f total=%.0f",
                      srcw, srch, outw, outh, ohq.texsize,
                      ohq.static_threshold, ohq.dynamic_threshold,
                      ohq_last_table_cached ? "cached" : "rebuilt",
                      ctx_survived ? "SURVIVED" : "new",
                      ohq_t.synced ? "synced" : "submit",
                      ohq_t.entry, ohq_t.tex, ohq_t.prog, ohq_t.fbo,
                      ohq_t.table_build, ohq_t.table_upload, ohq_t.total);
    return true;
}

void OpenGLHQ_Resize(int outx, int outy, int outw, int outh)
{
    if (!ohq.active) return;
    ohq.outx = outx; ohq.outy = outy;
    if (outw == ohq.outw && outh == ohq.outh) return;
    ohq.outw = outw; ohq.outh = outh;
    build_interp_texture(outw, outh);
}

void OpenGLHQ_UploadRows(const void *pixels, int pitch, int y, int height)
{
    if (!ohq.active) return;
    ohq_ActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, ohq.texture[0]);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, pitch / 4);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, ohq.srcw, height,
                    GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, pixels);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
}

/* Two different orientations are needed, and getting them the wrong way round
 * is silent rather than fatal, so they are spelled out.
 *
 * Passes 1 and 2 are texture->texture and must be an IDENTITY in texture space:
 * FBO texel row r has to hold the result computed for source texel row r, or
 * the next pass reads the wrong neighbourhood.  v=0 therefore maps to NDC
 * y=-1, which is FBO row 0.
 *
 * Pass 3 is texture->screen and must match DOSBox's own display list, which
 * puts v=0 at the TOP (glTexCoord2f(0,0) -> glVertex2f(-1,1)) because the
 * emulated framebuffer's row 0 is the top of the DOS screen.  Reusing the
 * pass-1 quad here would mirror the picture vertically. */
static void draw_quad(bool flip_v)
{
    const GLfloat v0 = flip_v ? ohq.tex_h : 0.0f;   /* at NDC y = -1 */
    const GLfloat v1 = flip_v ? 0.0f : ohq.tex_h;   /* at NDC y = +1 */
    glBegin(GL_QUADS);
    glTexCoord2f(0,         v0); glVertex2f(-1.0f, -1.0f);
    glTexCoord2f(ohq.tex_w, v0); glVertex2f( 1.0f, -1.0f);
    glTexCoord2f(ohq.tex_w, v1); glVertex2f( 1.0f,  1.0f);
    glTexCoord2f(0,         v1); glVertex2f(-1.0f,  1.0f);
    glEnd();
}

void OpenGLHQ_Render(void)
{
    if (!ohq.active) return;

    /* Once per context, not per frame.  A successful Init only proves the
     * programs compiled; this proves GFX_EndUpdate actually dispatches here,
     * which is the part the wiring could get wrong without any symptom -- the
     * stock display-list path draws a perfectly good unscaled picture. */
    if (!ohq.render_probed) {
        ohq.render_probed = true;
        OpenGLHQ_ProbeLog("render first frame");
    }

    glEnable(GL_FRAGMENT_PROGRAM_ARB);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);

    /* --- pass 1: source -> texture[1] --------------------------------- */
    ohq_ActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, ohq.texture[0]);
    ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, ohq.fbo[0]);
    /* srcw x srch, NOT texsize x texsize.  The quad spans texcoords 0..tex_w,
     * and the next pass reads back over that same 0..tex_w range, so the
     * rasterised area has to be exactly the tex_w fraction of the FBO:
     *   x = (u / tex_w) * viewport_w  must equal  u * texsize
     *   => viewport_w = tex_w * texsize = srcw
     * A texsize viewport stretches the source across the whole FBO and pass 2
     * then samples only its top-left corner. */
    glViewport(0, 0, ohq.srcw, ohq.srch);
    ohq_BindProgramARB(GL_FRAGMENT_PROGRAM_ARB, ohq.program[0]);
    ohq_ProgramLocalParameter4dARB(GL_FRAGMENT_PROGRAM_ARB, 0,
        ((double)ohq.static_threshold) / 255.0, 0.0,
        0.0, ((double)ohq.dynamic_threshold) / 100.0);
    ohq_ProgramEnvParameter4dARB(GL_FRAGMENT_PROGRAM_ARB, 0,
        1.0 / ohq.texsize - 1.0 / 4096, 1.0 / ohq.texsize - 1.0 / 4096,
        ohq.texsize, ohq.texsize);
    draw_quad(false);

    /* --- pass 2: texture[1] -> texture[2] ------------------------------ */
    glBindTexture(GL_TEXTURE_2D, ohq.texture[1]);
    ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, ohq.fbo[1]);
    ohq_BindProgramARB(GL_FRAGMENT_PROGRAM_ARB, ohq.program[1]);
    ohq_ProgramLocalParameter4dARB(GL_FRAGMENT_PROGRAM_ARB, 0,
        ((double)ohq.static_threshold) / 255.0, 0.0,
        0.0, ((double)ohq.dynamic_threshold) / 100.0);
    draw_quad(false);

    /* --- pass 3: (source, texture[2], 3D table) -> screen -------------- */
    ohq_BindFramebufferEXT(GL_FRAMEBUFFER_EXT, 0);
    /* Back to DOSBox's clip rectangle, which is where its own glCallList path
     * draws -- letterbox bars included. */
    glViewport(ohq.outx, ohq.outy, ohq.outw, ohq.outh);
    ohq_ActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, ohq.texture[0]);
    ohq_ActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, ohq.texture[2]);
    ohq_ActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_3D, ohq.texture[3]);
    ohq_ActiveTexture(GL_TEXTURE0);
    ohq_BindProgramARB(GL_FRAGMENT_PROGRAM_ARB, ohq.program[2]);
    ohq_ProgramEnvParameter4dARB(GL_FRAGMENT_PROGRAM_ARB, 0,
        1.0 / ohq.texsize, 1.0 / ohq.texsize, ohq.texsize, ohq.texsize);
    draw_quad(true);

    glDisable(GL_FRAGMENT_PROGRAM_ARB);
}

void OpenGLHQ_Shutdown(void)
{
    if (ohq.program[0] || ohq.program[1] || ohq.program[2])
        ohq_DeleteProgramsARB(3, ohq.program);
    if (ohq.fbo[0] || ohq.fbo[1])
        ohq_DeleteFramebuffersEXT(2, ohq.fbo);
    if (ohq.texture[0])
        glDeleteTextures(4, ohq.texture);
    memset(&ohq, 0, sizeof(ohq));
}

#endif /* C_OPENGL */
