/*
 * launcher.c -- dosbox-daum.app/Contents/MacOS/dosbox-daum
 *
 * A universal trampoline in front of the real dosbox binary.  It exists for
 * three reasons:
 *
 *   1. Finder passes a "-psn_0_12345" process-serial-number argument to
 *      bundled apps.  DOSBox parses argv itself and would treat that as a
 *      file to mount, then fail.  We drop it.
 *   2. It locates the bundle from its own path, so the app works from any
 *      directory with no compiled-in absolute paths.
 *   3. It points munt and FluidSynth at the bundled MT-32 ROM and SoundFont
 *      directories, which have no other way to be discovered.
 *
 * Unlike the Wine launcher this does no architecture juggling: the real binary
 * is universal and runs natively on both Intel and Apple Silicon.  That is the
 * whole point of porting the AArch64 dynamic recompiler rather than leaning on
 * Rosetta.
 *
 * Build:
 *   clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
 *         -O2 -Wall -o dosbox-daum launcher.c
 */

#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "dosbox-daum: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

static char *self_path(void)
{
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);

    char *raw = malloc(size + 1);
    if (!raw || _NSGetExecutablePath(raw, &size) != 0)
        die("cannot determine my own path");
    raw[size] = '\0';

    char *resolved = malloc(PATH_MAX);
    if (!resolved || !realpath(raw, resolved))
        die("cannot resolve %s: %s", raw, strerror(errno));

    free(raw);
    return resolved;
}

static char *join(const char *a, const char *b)
{
    size_t n = strlen(a) + strlen(b) + 2;
    char *s = malloc(n);
    if (!s) die("out of memory");
    snprintf(s, n, "%s/%s", a, b);
    return s;
}

static int path_exists(const char *p)
{
    struct stat st;
    return stat(p, &st) == 0;
}

int main(int argc, char *argv[])
{
    char *me       = self_path();               /* .../Contents/MacOS/dosbox-daum */
    char *macos    = strdup(dirname(strdup(me)));
    char *contents = strdup(dirname(strdup(macos)));

    char *resources = join(contents, "Resources");
    char *root      = join(resources, "daum");
    char *real      = join(root, "bin/dosbox");

    if (!path_exists(real))
        die("bundle is incomplete: %s is missing", real);

    /* Bundled audio data, if present. */
    char *romdir = join(root, "share/mt32-roms");
    char *sfdir  = join(root, "share/soundfonts");
    if (path_exists(romdir)) setenv("MT32_ROM_DIR", romdir, 0);
    if (path_exists(sfdir))  setenv("SOUNDFONT_DIR", sfdir, 0);
    setenv("DOSBOX_DAUM_ROOT", root, 1);

    if (getenv("DOSBOX_APP_DEBUG")) {
        fprintf(stderr, "dosbox-daum: root = %s\n", root);
        fprintf(stderr, "dosbox-daum: exec = %s\n", real);
    }

    /* Copy argv, dropping the process-serial-number argument Finder adds. */
    char **child = calloc((size_t)argc + 1, sizeof(char *));
    int n = 0;
    child[n++] = real;
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "-psn_", 5) == 0) continue;
        child[n++] = argv[i];
    }
    child[n] = NULL;

    execv(real, child);
    die("cannot execute %s: %s", real, strerror(errno));
}
