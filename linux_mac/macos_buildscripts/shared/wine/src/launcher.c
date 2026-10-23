/*
 * launcher.c -- wine.app/Contents/MacOS/wine
 *
 * A small universal (arm64 + x86_64) trampoline.  Its jobs are:
 *
 *   1. Locate the bundle from its own path, with no compiled-in absolute
 *      paths, so wine.app is portable to any directory or volume.
 *   2. Export the handful of environment variables that GStreamer needs in
 *      order to find its bundled plugins (Wine itself derives everything from
 *      the loader path, so it needs nothing), and quiet MoltenVK's default
 *      informational logging.
 *   3. On Apple Silicon, confirm Rosetta 2 is present before exec'ing an
 *      x86_64 loader, and offer to install it if it is not.  This is what
 *      makes the bundle work on a genuinely fresh macOS install.
 *   4. exec() the real loader, replacing this process, so signals, exit codes
 *      and stdio all behave exactly as if wine had been invoked directly.
 *
 * Build:
 *   clang -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
 *         -O2 -Wall -o wine launcher.c
 */

#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char **environ;

static void die(const char *fmt, ...) __attribute__((noreturn, format(printf, 1, 2)));

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "wine: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    exit(1);
}

/* Absolute, symlink-resolved path of this executable. */
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

static void set_env(const char *k, const char *v, int overwrite)
{
    if (setenv(k, v, overwrite) != 0)
        die("setenv(%s) failed: %s", k, strerror(errno));
}

static void prepend_path(const char *dir)
{
    const char *cur = getenv("PATH");
    if (!cur) cur = "/usr/bin:/bin:/usr/sbin:/sbin";
    size_t n = strlen(dir) + strlen(cur) + 2;
    char *s = malloc(n);
    if (!s) die("out of memory");
    snprintf(s, n, "%s:%s", dir, cur);
    set_env("PATH", s, 1);
    free(s);
}

/* ------------------------------------------------------------------ Rosetta */

#if defined(__arm64__) || defined(__aarch64__)

static int run_quiet(const char *const argv[])
{
    pid_t pid;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    int rc = posix_spawn(&pid, argv[0], &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) return -1;

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int rosetta_available(void)
{
    /* Fast path: the Rosetta runtime is installed at a well-known location. */
    if (path_exists("/Library/Apple/usr/libexec/oah/libRosettaRuntime") ||
        path_exists("/Library/Apple/usr/libexec/oah/RosettaLinux") ||
        path_exists("/usr/libexec/rosetta/oahd"))
        return 1;

    /* Definitive path: actually try to execute an x86_64 binary. */
    const char *const argv[] = { "/usr/bin/arch", "-x86_64", "/usr/bin/true", NULL };
    return run_quiet(argv) == 0;
}

static void ensure_rosetta(void)
{
    if (rosetta_available()) return;

    if (isatty(STDERR_FILENO)) {
        fprintf(stderr,
            "wine: Rosetta 2 is required to run x86 Windows programs on Apple Silicon,\n"
            "      but it is not installed.  Install it with:\n\n"
            "          softwareupdate --install-rosetta --agree-to-license\n\n");
        exit(1);
    }

    const char *script =
        "set q to display dialog "
        "\"Wine needs Rosetta 2 to run Windows programs on this Mac.\\n\\n"
        "Rosetta is a free Apple component. Install it now?\" "
        "buttons {\"Quit\", \"Install\"} default button \"Install\" with icon caution\n"
        "if button returned of q is \"Install\" then\n"
        "  do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" "
        "with administrator privileges\n"
        "else\n"
        "  error number -128\n"
        "end if";

    const char *const argv[] = { "/usr/bin/osascript", "-e", script, NULL };
    if (run_quiet(argv) != 0)
        exit(1);

    if (!rosetta_available())
        die("Rosetta 2 installation did not complete");
}

#else
static void ensure_rosetta(void) { }
#endif

/* --------------------------------------------------------------------- main */

int main(int argc, char *argv[])
{
    char *me       = self_path();                    /* .../Contents/MacOS/wine   */
    char *macos    = strdup(dirname(strdup(me)));    /* .../Contents/MacOS        */
    char *contents = strdup(dirname(strdup(macos))); /* .../Contents              */

    char *resources = join(contents, "Resources");
    char *root      = join(resources, "wine");       /* the installed wine tree   */
    char *bindir    = join(root, "bin");
    char *libdir    = join(root, "lib");
    char *loader    = join(bindir, "wine");

    if (!path_exists(loader))
        die("bundle is incomplete: %s is missing", loader);

    /* GStreamer cannot derive its own location, so point it at the bundle. */
    char *gstplugins = join(libdir, "gstreamer-1.0");
    char *gstscanner = join(root, "libexec/gstreamer-1.0/gst-plugin-scanner");
    if (path_exists(gstplugins)) {
        set_env("GST_PLUGIN_SYSTEM_PATH_1_0", gstplugins, 1);
        set_env("GST_PLUGIN_PATH_1_0", gstplugins, 1);
    }
    if (path_exists(gstscanner))
        set_env("GST_PLUGIN_SCANNER_1_0", gstscanner, 1);

    /* Keep GStreamer's plugin cache out of the (possibly read-only) bundle. */
    const char *home = getenv("HOME");
    if (home && *home) {
        char *cache = join(home, "Library/Caches/org.winehq.wine");
        mkdir(cache, 0755);
        char *reg = join(cache, "gstreamer-registry.bin");
        set_env("GST_REGISTRY_1_0", reg, 0);
    }

    /* Quiet MoltenVK.  Its MVK_CONFIG_LOG_LEVEL defaults to 3 (errors +
       warnings + informational), which makes every single Vulkan instance
       creation print a ~160-line banner to stderr: the MoltenVK version, all
       153 supported Vulkan extensions, the GPU model and its feature sets.
       winevulkan creates an instance during ordinary startup, so this lands in
       front of the output of even `wine cmd /c echo hi`.

       1 is errors only.  2 additionally keeps warnings, which is worth
       considering if a Vulkan problem ever needs diagnosing -- though the
       simpler move is to override this at run time, which the 0 below permits:

           MVK_CONFIG_LOG_LEVEL=3 wine ...

       Note this cannot be set from wine.inf or the registry: MoltenVK reads it
       from the process environment, so it has to be here, in the one place that
       runs before the loader. */
    set_env("MVK_CONFIG_LOG_LEVEL", "1", 0);

    /* Wine derives WINEDATADIR/WINEDLLPATH from the loader path; giving it
       WINELOADER explicitly makes child processes reuse this exact tree. */
    set_env("WINELOADER", loader, 1);
    prepend_path(bindir);

    if (getenv("WINE_APP_DEBUG")) {
        fprintf(stderr, "wine: root       = %s\n", root);
        fprintf(stderr, "wine: loader     = %s\n", loader);
        fprintf(stderr, "wine: gstplugins = %s\n", gstplugins);
    }

    ensure_rosetta();

    /* Build the argument vector for the real loader.  LaunchServices exports
       __CFBundleIdentifier into every app it starts, which distinguishes a
       double-click in Finder from a plain shell invocation far more reliably
       than looking at whether stdin is a terminal.  In that case, and with no
       arguments to act on, open winecfg rather than printing usage into the
       void. */
    int finder_launch = (argc == 1 && getenv("__CFBundleIdentifier") != NULL) ||
                        (argc > 1 && strncmp(argv[1], "-psn_", 5) == 0);

    char **child;
    if (finder_launch) {
        child = calloc(3, sizeof(char *));
        child[0] = loader;
        child[1] = (char *)"winecfg";
        child[2] = NULL;
    } else {
        child = calloc(argc + 1, sizeof(char *));
        child[0] = loader;
        for (int i = 1; i < argc; i++) child[i] = argv[i];
        child[argc] = NULL;
    }

    execv(loader, child);
    die("cannot execute %s: %s", loader, strerror(errno));
}
