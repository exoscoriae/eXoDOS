/*
 * wget_macos_bundle.h - locate data shipped inside wget.app
 *
 * Part of the portable macOS bundle build of GNU Wget2.  The executable lives
 * at wget.app/Contents/MacOS/wget; its data (CA snapshot, HSTS preload list,
 * DNSSEC trust anchors, translations, bundled GnuPG) lives in
 * wget.app/Contents/Resources.  Nothing here is compiled on other platforms.
 *
 * WGET2_MACOS_RESOURCES may point at a Resources directory explicitly; this
 * is meant for testing a binary that was copied out of the bundle.
 */

#ifndef WGET_MACOS_BUNDLE_H
#define WGET_MACOS_BUNDLE_H

#ifdef __APPLE__

#include <mach-o/dyld.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static __attribute__((__unused__)) int wget_macos_is_dir(const char *path)
{
	struct stat st;

	return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* Absolute path of .../wget.app/Contents/Resources, or NULL if the running
 * executable is not inside an application bundle.  Computed once; the
 * result stays valid for the lifetime of the process. */
static __attribute__((__unused__)) const char *wget_macos_resources_dir(void)
{
	static int done;
	static char *resdir;
	char buf[PATH_MAX + 1], *exe = buf, *real, *slash, *res;
	uint32_t size = sizeof(buf);
	const char *env;
	size_t n;

	if (done)
		return resdir;
	done = 1;

	env = getenv("WGET2_MACOS_RESOURCES");
	if (env && *env == '/' && wget_macos_is_dir(env)) {
		resdir = strdup(env);
		return resdir;
	}

	if (_NSGetExecutablePath(buf, &size) != 0) {
		/* buffer too small; SIZE now holds the required size */
		if (!(exe = malloc(size + 1)))
			return NULL;
		if (_NSGetExecutablePath(exe, &size) != 0) {
			free(exe);
			return NULL;
		}
	}

	real = realpath(exe, NULL); /* resolves symlinks, e.g. /usr/local/bin/wget */
	if (exe != buf)
		free(exe);
	if (!real)
		return NULL;

	/* .../Contents/MacOS/wget -> .../Contents */
	if (!(slash = strrchr(real, '/'))) {
		free(real);
		return NULL;
	}
	*slash = 0;
	if (!(slash = strrchr(real, '/')) || strcmp(slash, "/MacOS") != 0) {
		free(real);
		return NULL;
	}
	*slash = 0;

	n = strlen(real);
	if ((res = malloc(n + sizeof("/Resources")))) {
		memcpy(res, real, n);
		memcpy(res + n, "/Resources", sizeof("/Resources"));
		if (wget_macos_is_dir(res))
			resdir = res;
		else
			free(res);
	}
	free(real);

	return resdir;
}

/* malloc()ed absolute path of RELPATH inside Contents/Resources if that file
 * or directory exists, otherwise NULL.  Release with free(). */
static __attribute__((__unused__)) char *wget_macos_resource_path(const char *relpath)
{
	const char *dir = wget_macos_resources_dir();
	size_t dlen, rlen;
	char *path;
	struct stat st;

	if (!dir || !relpath)
		return NULL;

	dlen = strlen(dir);
	rlen = strlen(relpath);
	if (!(path = malloc(dlen + 1 + rlen + 1)))
		return NULL;
	memcpy(path, dir, dlen);
	path[dlen] = '/';
	memcpy(path + dlen + 1, relpath, rlen + 1);

	if (stat(path, &st) != 0) {
		free(path);
		return NULL;
	}

	return path;
}

#endif /* __APPLE__ */

#endif /* WGET_MACOS_BUNDLE_H */
