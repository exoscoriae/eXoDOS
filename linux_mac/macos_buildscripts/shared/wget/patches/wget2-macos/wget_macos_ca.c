/*
 * wget_macos_ca.c - keep wget2's CA trust current on macOS
 *
 * Part of the portable macOS bundle build of GNU Wget2.  This file is
 * #included by libwget/ssl_gnutls.c (on __APPLE__ only) and provides
 * wget_macos_ca_bundle_path(), which replaces wget_ssl_default_ca_bundle_path()
 * for the default "--ca-certificate=system" case.
 *
 * Trust sources used by the bundle build, all evaluated at run time:
 *
 *  1. The macOS Keychain (system roots plus anything an administrator, MDM
 *     profile or the user added or distrusted).  This is loaded by GnuTLS'
 *     gnutls_certificate_set_x509_system_trust(), which the bundle build
 *     patches to honour the Keychain trust settings; a "Never Trust" setting
 *     also blocks the CA when the Mozilla bundle below contains it.
 *
 *  2. The Mozilla CA bundle as published by the curl project
 *     (https://curl.se/ca/cacert.pem).  A snapshot taken at build time ships
 *     in wget.app/Contents/Resources/ca/cacert.pem, and a per-user copy in
 *     ~/Library/Caches/wget2/cacert.pem is refreshed over HTTPS (at most once
 *     per WGET_CA_UPDATE_INTERVAL hours, default 24; conditional GET, with an
 *     unconditional one at least weekly).  The newer of the two is used.  This
 *     keeps wget2 current on Macs whose macOS no longer receives updates,
 *     e.g. macOS 11.
 *
 * The refresh is verified with the trust from (1) and the bundle currently in
 * use.  A download must parse completely, must not be older than the shipped
 * snapshot and must not be dated in the future.  The whole refresh is limited
 * to MCA_TOTAL_TIMEOUT_MS.  Failures never break a download: the previous
 * bundle stays in use, and retries back off from one hour to one day.
 *
 * Environment:
 *   WGET_CA_AUTO_UPDATE=0        never contact the network for CA updates
 *   WGET_CA_UPDATE_INTERVAL=N    hours between checks (0 = check every run)
 *   WGET_CA_UPDATE_URL=https://  alternative source (e.g. an internal mirror)
 *   https_proxy / no_proxy       an http:// proxy for the refresh (CONNECT)
 *   XDG_CACHE_HOME               cache location instead of ~/Library/Caches
 *                                (ignored when running as root)
 */

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <gnutls/gnutls.h>
#include <gnutls/x509.h>

#ifndef WGET_MACOS_CA_STANDALONE
#	include "wget_macos_bundle.h"
#	define MCA_DEBUG(...) debug_printf(__VA_ARGS__)
#	define MCA_SNAPSHOT_PATH() wget_macos_resource_path("ca/cacert.pem")
#	define MCA_USER_AGENT "wget2/" PACKAGE_VERSION " (macOS CA bundle update)"
#endif
#ifndef MCA_IS_ROOT
#	define MCA_IS_ROOT() (geteuid() == 0)
#endif

#define MCA_DEFAULT_URL "https://curl.se/ca/cacert.pem"
#define MCA_HEADER "## Certificate data from Mozilla "
#define MCA_PEM_BEGIN "-----BEGIN CERTIFICATE-----"
#define MCA_MIN_CERTS 100
#define MCA_MAX_BYTES (16 * 1024 * 1024)
#define MCA_MAX_HEADER_BYTES 65536
#define MCA_DEFAULT_INTERVAL_HOURS 24
#define MCA_FULL_REFRESH_SECS (7 * 86400L)    /* unconditional GET after this */
#define MCA_MAX_FUTURE_SECS (2 * 86400L)      /* tolerated "as of" clock skew */
#define MCA_BACKOFF_MIN_SECS 3600L            /* after the first failure ... */
#define MCA_BACKOFF_MAX_SECS 86400L           /* ... doubling up to this */
#define MCA_CONNECT_TIMEOUT_MS 4000
#define MCA_IO_TIMEOUT_MS 5000
#define MCA_TOTAL_TIMEOUT_MS 10000            /* DNS + connect + TLS + HTTP */

typedef struct {
	time_t asof;
	int ncerts;
} mca_info_t;

typedef struct {
	char host[256];
	char port[8];
	char path[1024];
} mca_url_t;

typedef struct {
	int status;
	char *body;
	size_t body_len;
	char last_modified[128];
} mca_response_t;

/* ---------------------------------------------------------------- helpers */

static char *mca_printf(const char *fmt, ...) __attribute__((__format__(__printf__, 1, 2)));
static char *mca_printf(const char *fmt, ...)
{
	va_list ap;
	int n;
	char *s;

	va_start(ap, fmt);
	n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n < 0 || !(s = malloc((size_t) n + 1)))
		return NULL;
	va_start(ap, fmt);
	vsnprintf(s, (size_t) n + 1, fmt, ap);
	va_end(ap);
	return s;
}

/* Milliseconds on a clock that does not jump with the wall clock. */
static long long mca_now_ms(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		return (long long) time(NULL) * 1000;
	return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Milliseconds left until DEADLINE (0 when it has passed). */
static int mca_left_ms(long long deadline)
{
	long long r = deadline - mca_now_ms();

	return r <= 0 ? 0 : r > INT_MAX ? INT_MAX : (int) r;
}

static int mca_min(int a, int b)
{
	return a < b ? a : b;
}

static time_t mca_mtime(const char *path)
{
	struct stat st;

	return path && lstat(path, &st) == 0 && S_ISREG(st.st_mode) ? st.st_mtime : 0;
}

/* Search NEEDLE in the first N bytes of HAY. */
static const char *mca_find(const char *hay, size_t n, const char *needle)
{
	size_t nl = strlen(needle), i;

	for (i = 0; nl <= n && i <= n - nl; i++)
		if (hay[i] == needle[0] && !memcmp(hay + i, needle, nl))
			return hay + i;
	return NULL;
}

static int mca_mkdir_p(const char *path, mode_t mode)
{
	char *p, *s = strdup(path);
	struct stat st;
	int rc = 0;

	if (!s)
		return -1;
	for (p = s + 1; *p; p++) {
		if (*p != '/')
			continue;
		*p = 0;
		if (mkdir(s, 0755) != 0 && errno != EEXIST)
			rc = -1;
		*p = '/';
	}
	if (mkdir(s, mode) != 0 && errno != EEXIST)
		rc = -1;
	if (stat(s, &st) != 0 || !S_ISDIR(st.st_mode))
		rc = -1;
	free(s);
	return rc;
}

/* Read a whole regular file (NUL-terminated copy, at most MAX bytes). */
static int mca_read_file(const char *path, char **data, size_t *len, size_t max)
{
	struct stat st;
	char *buf;
	size_t got = 0;
	ssize_t n;
	int fd;

	*data = NULL;
	*len = 0;
	if ((fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)) < 0)
		return -1;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || (size_t) st.st_size > max) {
		close(fd);
		return -1;
	}
	if (!(buf = malloc((size_t) st.st_size + 1))) {
		close(fd);
		return -1;
	}
	while (got < (size_t) st.st_size) {
		n = read(fd, buf + got, (size_t) st.st_size - got);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		got += (size_t) n;
	}
	close(fd);
	if (got != (size_t) st.st_size) {
		free(buf);
		return -1;
	}
	buf[got] = 0;
	*data = buf;
	*len = got;
	return 0;
}

/* Write DATA to PATH via a new temporary file in the same directory. */
static int mca_write_atomic(const char *path, const void *data, size_t len)
{
	char *tmp = mca_printf("%s.tmp.%ld", path, (long) getpid());
	const char *p = data;
	size_t done = 0;
	ssize_t n;
	int fd, rc = -1;

	if (!tmp)
		return -1;
	fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd < 0 && errno == EEXIST && unlink(tmp) == 0) /* left over by a crash */
		fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd >= 0) {
		while (done < len) {
			n = write(fd, p + done, len - done);
			if (n < 0 && errno == EINTR)
				continue;
			if (n <= 0)
				break;
			done += (size_t) n;
		}
		if (done == len && fsync(fd) == 0 && close(fd) == 0) {
			fd = -1;
			if (rename(tmp, path) == 0)
				rc = 0;
		}
		if (fd >= 0)
			close(fd);
		if (rc != 0)
			unlink(tmp);
	}
	free(tmp);
	return rc;
}

/* Create PATH if needed and set its modification time to now. */
static void mca_stamp(const char *path)
{
	int fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);

	if (fd >= 0) {
		futimes(fd, NULL);
		close(fd);
	}
}

/* ------------------------------------------------------ bundle inspection */

/* Parse "## Certificate data from Mozilla as of: Tue Jul 15 03:12:09 2025 GMT"
 * (curl's mk-ca-bundle.pl writes "downloaded on:" instead of "as of:" when the
 * upstream file date is unknown).  Done by hand: strptime() would depend on
 * the current LC_TIME locale. */
static int mca_parse_asof(const char *data, time_t *asof)
{
	static const char months[] = "JanFebMarAprMayJunJulAugSepOctNovDec";
	const char *p = strstr(data, MCA_HEADER), *m;
	char wday[4], mon[4];
	int d, H, M, S, Y;
	struct tm tm;
	time_t t;

	if (!p || p - data > 16384)
		return -1;
	p += sizeof(MCA_HEADER) - 1;
	if (!strncmp(p, "as of: ", 7))
		p += 7;
	else if (!strncmp(p, "downloaded on: ", 15))
		p += 15;
	else
		return -1;
	if (sscanf(p, "%3s %3s %d %d:%d:%d %d", wday, mon, &d, &H, &M, &S, &Y) != 7)
		return -1;
	if (strlen(mon) != 3 || !(m = strstr(months, mon)) || (m - months) % 3)
		return -1;
	if (Y < 2000 || Y > 2200 || d < 1 || d > 31 || H < 0 || H > 23 || M < 0 || M > 59 || S < 0 || S > 60)
		return -1;

	memset(&tm, 0, sizeof(tm));
	tm.tm_year = Y - 1900;
	tm.tm_mon = (int) ((m - months) / 3);
	tm.tm_mday = d;
	tm.tm_hour = H;
	tm.tm_min = M;
	tm.tm_sec = S;
	if ((t = timegm(&tm)) == (time_t) -1)
		return -1;
	*asof = t;
	return 0;
}

static int mca_count_pem(const char *data)
{
	const char *p = data;
	int n = 0;

	while ((p = strstr(p, MCA_PEM_BEGIN))) {
		n++;
		p += sizeof(MCA_PEM_BEGIN) - 1;
	}
	return n;
}

/* Number of certificates GnuTLS can import from DATA (all must parse). */
static int mca_count_parsed(const char *data, size_t len)
{
	gnutls_datum_t d = { (unsigned char *) data, (unsigned int) len };
	gnutls_x509_crt_t *crts = NULL;
	unsigned int n = 0, i;
	int rc;

	rc = gnutls_x509_crt_list_import2(&crts, &n, &d, GNUTLS_X509_FMT_PEM, 0);
	if (rc < 0)
		return rc;
	for (i = 0; i < n; i++)
		gnutls_x509_crt_deinit(crts[i]);
	gnutls_free(crts);
	return (int) n;
}

/* Inspect a Mozilla bundle in memory.  FULL additionally parses every
 * certificate (used for downloads before they are accepted).  A bundle dated
 * after NOT_AFTER (if not 0) is refused: such a date can only come from a
 * forged file, which would otherwise win over every genuine update.
 * Returns 0, -1 (not a valid bundle) or -2 (dated in the future). */
static int mca_info_mem(const char *data, size_t len, int full, time_t not_after, mca_info_t *info)
{
	int n;

	if (mca_parse_asof(data, &info->asof) != 0)
		return -1;
	if (not_after && info->asof > not_after)
		return -2;
	n = mca_count_pem(data);
	if (n < MCA_MIN_CERTS)
		return -1;
	if (full && mca_count_parsed(data, len) != n)
		return -1;
	info->ncerts = n;
	return 0;
}

static int mca_info_file(const char *path, int full, time_t not_after, mca_info_t *info)
{
	char *data;
	size_t len;
	int rc;

	if (!path || mca_read_file(path, &data, &len, MCA_MAX_BYTES) != 0)
		return -1;
	rc = mca_info_mem(data, len, full, not_after, info);
	free(data);
	return rc;
}

/* The newer valid bundle of CACHE and SNAPSHOT (malloc()ed path) or NULL. */
static char *mca_choose(const char *cache, const char *snapshot, mca_info_t *out)
{
	mca_info_t ci, si;
	int cok = mca_info_file(cache, 0, time(NULL) + MCA_MAX_FUTURE_SECS, &ci) == 0;
	int sok = mca_info_file(snapshot, 0, 0, &si) == 0;

	if (cok && (!sok || ci.asof >= si.asof)) {
		*out = ci;
		return strdup(cache);
	}
	if (sok) {
		*out = si;
		return strdup(snapshot);
	}
	return NULL;
}

/* ------------------------------------------------------------- locations */

/* No other (non-root) user may be able to replace DIR or any directory
 * above it, now or while the cache is used: each one must be owned by root
 * or by us and must not be writable by group or others, unless it has the
 * sticky bit (like /tmp), which stops others from renaming our entries. */
static int mca_path_is_safe(const char *dir)
{
	char *real = realpath(dir, NULL);
	struct stat st;
	size_t n;
	int ok = 1;

	if (!real)
		return 0;
	for (n = strlen(real);;) {
		if (stat(n ? real : "/", &st) != 0
			|| (st.st_uid != 0 && st.st_uid != geteuid())
			|| ((st.st_mode & (S_IWGRP | S_IWOTH)) && !(st.st_mode & S_ISVTX))) {
			ok = 0;
			break;
		}
		if (n == 0)
			break;
		while (n > 0 && real[n - 1] != '/') /* drop the last component */
			n--;
		if (n > 0)
			n--;
		real[n] = 0;
	}
	free(real);
	return ok;
}

/* The cache must be a real directory that only this user can write to, in
 * a location no other user can tamper with: anything else could let another
 * local user plant a CA bundle. */
static int mca_dir_is_private(const char *dir)
{
	struct stat st;

	if (lstat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
		return 0;
	if (st.st_uid != geteuid() || (st.st_mode & (S_IWGRP | S_IWOTH)))
		return 0;
	return access(dir, W_OK) == 0 && mca_path_is_safe(dir);
}

static char *mca_cache_dir(void)
{
	const char *xdg = NULL, *home = NULL;
	char *dir;

	/* "sudo wget" keeps the invoking user's HOME (and sudo -E even
	 * XDG_CACHE_HOME); root must neither use nor leave root-owned files in
	 * a cache the user controls, so root always uses its own home. */
	if (!MCA_IS_ROOT()) {
		xdg = getenv("XDG_CACHE_HOME");
		home = getenv("HOME");
	}

	if (xdg && *xdg == '/') {
		dir = mca_printf("%s/wget2", xdg);
	} else {
		if (!home || *home != '/') {
#ifdef MCA_ROOT_HOME
			home = MCA_ROOT_HOME();
#else
			struct passwd *pw = getpwuid(geteuid());
			home = pw ? pw->pw_dir : NULL;
#endif
			if (!home || *home != '/')
				return NULL;
		}
		dir = mca_printf("%s/Library/Caches/wget2", home);
	}

	if (dir && (mca_mkdir_p(dir, 0700) != 0 || !mca_dir_is_private(dir))) {
		MCA_DEBUG("CA update: %s is not a private, writable directory; not using it\n", dir);
		free(dir);
		dir = NULL;
	}
	return dir;
}

/* ------------------------------------------------------------- networking */

static int mca_parse_https_url(const char *url, mca_url_t *u)
{
	const char *p, *host_end, *port = NULL;
	size_t n;

	memset(u, 0, sizeof(*u));
	if (strncasecmp(url, "https://", 8) != 0)
		return -1;
	p = url + 8;

	if (*p == '[') { /* IPv6 literal */
		if (!(host_end = strchr(p, ']')))
			return -1;
		n = (size_t) (host_end - p - 1);
		if (n == 0 || n >= sizeof(u->host))
			return -1;
		memcpy(u->host, p + 1, n);
		p = host_end + 1;
	} else {
		n = strcspn(p, ":/?#");
		if (n == 0 || n >= sizeof(u->host))
			return -1;
		memcpy(u->host, p, n);
		p += n;
	}

	if (*p == ':') {
		port = ++p;
		n = strspn(p, "0123456789");
		if (n == 0 || n >= sizeof(u->port))
			return -1;
		memcpy(u->port, port, n);
		p += n;
	} else {
		strcpy(u->port, "443");
	}

	if (*p == '/') {
		n = strcspn(p, "#");
		if (n >= sizeof(u->path))
			return -1;
		memcpy(u->path, p, n);
	} else if (*p == 0 || *p == '#') {
		strcpy(u->path, "/");
	} else {
		return -1;
	}
	return 0;
}

static const char *mca_getenv2(const char *a, const char *b)
{
	const char *v = getenv(a);

	if (!v || !*v)
		v = getenv(b);
	return v && *v ? v : NULL;
}

static int mca_no_proxy(const char *host)
{
	const char *np = mca_getenv2("no_proxy", "NO_PROXY"), *p;
	size_t hlen = strlen(host), n;
	char tok[256];

	if (!np)
		return 0;
	for (p = np; *p; ) {
		while (*p == ',' || isspace((unsigned char) *p))
			p++;
		n = strcspn(p, ",");
		while (n > 0 && isspace((unsigned char) p[n - 1]))
			n--;
		if (n > 0 && n < sizeof(tok)) {
			memcpy(tok, p, n);
			tok[n] = 0;
			if (!strcmp(tok, "*"))
				return 1;
			const char *t = tok[0] == '.' ? tok + 1 : tok;
			size_t tlen = strlen(t);
			if (tlen && (!strcasecmp(host, t)
				|| (hlen > tlen && host[hlen - tlen - 1] == '.' && !strcasecmp(host + hlen - tlen, t))))
				return 1;
		}
		p += strcspn(p, ",");
	}
	return 0;
}

static int mca_hexval(int c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

static void mca_percent_decode(char *s)
{
	char *d = s;

	for (; *s; s++) {
		if (*s == '%' && mca_hexval(s[1]) >= 0 && mca_hexval(s[2]) >= 0) {
			*d++ = (char) (mca_hexval(s[1]) * 16 + mca_hexval(s[2]));
			s += 2;
		} else {
			*d++ = *s;
		}
	}
	*d = 0;
}

static char *mca_base64(const char *src)
{
	static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	size_t len = strlen(src), i, o = 0;
	const unsigned char *s = (const unsigned char *) src;
	char *out = malloc((len + 2) / 3 * 4 + 1);

	if (!out)
		return NULL;
	for (i = 0; i + 2 < len; i += 3) {
		out[o++] = tbl[s[i] >> 2];
		out[o++] = tbl[((s[i] & 3) << 4) | (s[i + 1] >> 4)];
		out[o++] = tbl[((s[i + 1] & 15) << 2) | (s[i + 2] >> 6)];
		out[o++] = tbl[s[i + 2] & 63];
	}
	if (i < len) {
		out[o++] = tbl[s[i] >> 2];
		if (i + 1 < len) {
			out[o++] = tbl[((s[i] & 3) << 4) | (s[i + 1] >> 4)];
			out[o++] = tbl[(s[i + 1] & 15) << 2];
		} else {
			out[o++] = tbl[(s[i] & 3) << 4];
			out[o++] = '=';
		}
		out[o++] = '=';
	}
	out[o] = 0;
	return out;
}

/* Proxy for HOST from the environment.  Returns 1 and fills PROXY (and AUTH,
 * a "Basic ..." credential or NULL) if one must be used, 0 for a direct
 * connection, -1 if a proxy is configured that this code cannot use. */
static int mca_proxy_for(const char *host, mca_url_t *proxy, char **auth)
{
	const char *env = mca_getenv2("https_proxy", "HTTPS_PROXY"), *p, *at, *hp;
	char authority[512], *userinfo = NULL;
	size_t n;

	*auth = NULL;
	if (!env)
		env = mca_getenv2("all_proxy", "ALL_PROXY");
	if (!env || mca_no_proxy(host))
		return 0;

	p = env;
	if (strstr(p, "://")) {
		if (strncasecmp(p, "http://", 7) != 0)
			return -1; /* https:// or socks proxies are not supported here */
		p += 7;
	}
	n = strcspn(p, "/?#");
	if (n == 0 || n >= sizeof(authority))
		return -1;
	memcpy(authority, p, n);
	authority[n] = 0;

	hp = authority;
	if ((at = strrchr(authority, '@'))) {
		userinfo = authority;
		authority[at - authority] = 0;
		hp = at + 1;
	}

	memset(proxy, 0, sizeof(*proxy));
	if (*hp == '[') {
		const char *e = strchr(hp, ']');
		if (!e || (size_t) (e - hp - 1) >= sizeof(proxy->host) || e == hp + 1)
			return -1;
		memcpy(proxy->host, hp + 1, (size_t) (e - hp - 1));
		hp = e + 1;
	} else {
		n = strcspn(hp, ":");
		if (n == 0 || n >= sizeof(proxy->host))
			return -1;
		memcpy(proxy->host, hp, n);
		hp += n;
	}
	if (*hp == ':' && hp[1]) {
		n = strspn(hp + 1, "0123456789");
		if (n == 0 || n >= sizeof(proxy->port) || hp[1 + n])
			return -1;
		memcpy(proxy->port, hp + 1, n);
	} else {
		strcpy(proxy->port, "80");
	}

	if (userinfo && *userinfo) {
		mca_percent_decode(userinfo);
		if (!strchr(userinfo, ':')) {
			char *tmp = mca_printf("%s:", userinfo);
			*auth = tmp ? mca_base64(tmp) : NULL;
			free(tmp);
		} else {
			*auth = mca_base64(userinfo);
		}
		if (!*auth)
			return -1;
	}
	return 1;
}

/* Socket read/write timeouts: the smaller of MCA_IO_TIMEOUT_MS and the time
 * left until DEADLINE (at least 1 ms). */
static void mca_set_timeouts(int fd, long long deadline)
{
	int ms = mca_min(MCA_IO_TIMEOUT_MS, mca_left_ms(deadline));
	struct timeval tv;

	if (ms < 1)
		ms = 1;
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

/*
 * getaddrinfo() with a time limit: it has none of its own, so it runs in a
 * detached thread.  If the caller gives up, whichever side finishes last
 * frees the shared state (and the result).
 */
typedef struct {
	pthread_mutex_t mu;
	pthread_cond_t cv;
	int refs, done, rc;
	struct addrinfo *res;
	char host[256], port[8];
} mca_gai_t;

static void mca_gai_release(mca_gai_t *g)
{
	int last;

	pthread_mutex_lock(&g->mu);
	last = --g->refs == 0;
	pthread_mutex_unlock(&g->mu);
	if (last) {
		if (g->res)
			freeaddrinfo(g->res);
		pthread_cond_destroy(&g->cv);
		pthread_mutex_destroy(&g->mu);
		free(g);
	}
}

static void mca_gai_hints(struct addrinfo *hints)
{
	memset(hints, 0, sizeof(*hints));
	hints->ai_family = AF_UNSPEC;
	hints->ai_socktype = SOCK_STREAM;
	hints->ai_flags = AI_ADDRCONFIG;
}

static void *mca_gai_thread(void *arg)
{
	mca_gai_t *g = arg;
	struct addrinfo hints, *res = NULL;
	int rc;

	mca_gai_hints(&hints);
	rc = getaddrinfo(g->host, g->port, &hints, &res);
	pthread_mutex_lock(&g->mu);
	g->rc = rc;
	g->res = rc == 0 ? res : NULL;
	g->done = 1;
	pthread_cond_signal(&g->cv);
	pthread_mutex_unlock(&g->mu);
	mca_gai_release(g);
	return NULL;
}

static int mca_resolve(const char *host, const char *port, long long deadline, struct addrinfo **res)
{
	struct addrinfo hints;
	pthread_attr_t attr;
	pthread_t tid;
	mca_gai_t *g;
	int rc, started;

	*res = NULL;
	if (strlen(host) >= sizeof(g->host) || strlen(port) >= sizeof(g->port))
		return EAI_NONAME;
	if (!(g = calloc(1, sizeof(*g))))
		return EAI_MEMORY;
	strcpy(g->host, host);
	strcpy(g->port, port);
	pthread_mutex_init(&g->mu, NULL);
	pthread_cond_init(&g->cv, NULL);
	g->refs = 2;

	started = pthread_attr_init(&attr) == 0;
	if (started) {
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		started = pthread_create(&tid, &attr, mca_gai_thread, g) == 0;
		pthread_attr_destroy(&attr);
	}
	if (!started) { /* no thread: resolve synchronously */
		g->refs = 1;
		mca_gai_release(g);
		mca_gai_hints(&hints);
		return getaddrinfo(host, port, &hints, res);
	}

	pthread_mutex_lock(&g->mu);
	while (!g->done) {
		int ms = mca_left_ms(deadline);
		struct timespec ts;

		if (ms <= 0)
			break;
#ifdef __APPLE__
		ts.tv_sec = ms / 1000;
		ts.tv_nsec = (long) (ms % 1000) * 1000000L;
		pthread_cond_timedwait_relative_np(&g->cv, &g->mu, &ts);
#else
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_sec += ms / 1000;
		ts.tv_nsec += (long) (ms % 1000) * 1000000L;
		if (ts.tv_nsec >= 1000000000L) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000L;
		}
		pthread_cond_timedwait(&g->cv, &g->mu, &ts);
#endif
	}
	if (g->done) {
		rc = g->rc;
		*res = g->res;
		g->res = NULL; /* now owned by the caller */
	} else {
		rc = EAI_AGAIN;
	}
	pthread_mutex_unlock(&g->mu);
	mca_gai_release(g);

	if (rc == EAI_AGAIN && !*res)
		MCA_DEBUG("CA update: name lookup for %s timed out\n", host);
	return rc;
}

static int mca_tcp_connect(const char *host, const char *port, long long deadline)
{
	struct addrinfo *res = NULL, *ai;
	int fd = -1, rc, flags, err;
	socklen_t elen;
	struct pollfd pfd;

	if ((rc = mca_resolve(host, port, deadline, &res)) != 0) {
		MCA_DEBUG("CA update: cannot resolve %s: %s\n", host, gai_strerror(rc));
		return -1;
	}

	for (ai = res; ai && mca_left_ms(deadline) > 0; ai = ai->ai_next) {
		if ((fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol)) < 0)
			continue;
		fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
		{
			int on = 1;
			setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
		}
#endif
		flags = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);

		rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
		if (rc != 0 && errno == EINPROGRESS) {
			pfd.fd = fd;
			pfd.events = POLLOUT;
			do {
				pfd.revents = 0;
				rc = poll(&pfd, 1, mca_min(MCA_CONNECT_TIMEOUT_MS, mca_left_ms(deadline)));
			} while (rc < 0 && errno == EINTR);
			err = 0;
			elen = sizeof(err);
			if (rc == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0)
				rc = 0;
			else
				rc = -1;
		}

		if (rc == 0) {
			fcntl(fd, F_SETFL, flags);
			mca_set_timeouts(fd, deadline);
			break;
		}
		close(fd);
		fd = -1;
	}

	if (res)
		freeaddrinfo(res);
	if (fd < 0)
		MCA_DEBUG("CA update: cannot connect to %s port %s\n", host, port);
	return fd;
}

static int mca_fd_send_all(int fd, const char *buf, size_t len, long long deadline)
{
	ssize_t n;

	while (len > 0) {
		if (mca_left_ms(deadline) <= 0)
			return -1;
		mca_set_timeouts(fd, deadline);
		n = send(fd, buf, len, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -1;
		buf += n;
		len -= (size_t) n;
	}
	return 0;
}

/* Open a tunnel through an HTTP proxy.  Reads the reply byte by byte so that
 * nothing of the TLS stream that follows is consumed. */
static int mca_proxy_connect(const mca_url_t *proxy, const char *auth, const char *host, const char *port,
	long long deadline)
{
	char req[1024], resp[8192];
	size_t got = 0;
	ssize_t n;
	int fd, code = 0;

	if ((fd = mca_tcp_connect(proxy->host, proxy->port, deadline)) < 0)
		return -1;

	snprintf(req, sizeof(req),
		"CONNECT %s%s%s:%s HTTP/1.1\r\nHost: %s%s%s:%s\r\n%s%s%sUser-Agent: %s\r\n\r\n",
		strchr(host, ':') ? "[" : "", host, strchr(host, ':') ? "]" : "", port,
		strchr(host, ':') ? "[" : "", host, strchr(host, ':') ? "]" : "", port,
		auth ? "Proxy-Authorization: Basic " : "", auth ? auth : "", auth ? "\r\n" : "",
		MCA_USER_AGENT);
	if (mca_fd_send_all(fd, req, strlen(req), deadline) != 0)
		goto fail;

	while (got < sizeof(resp) - 1) {
		if (mca_left_ms(deadline) <= 0) {
			MCA_DEBUG("CA update: proxy %s did not answer in time\n", proxy->host);
			goto fail;
		}
		mca_set_timeouts(fd, deadline);
		n = recv(fd, resp + got, 1, 0);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			goto fail;
		got++;
		if (got >= 4 && !memcmp(resp + got - 4, "\r\n\r\n", 4))
			break;
	}
	resp[got] = 0;
	if (sscanf(resp, "HTTP/%*d.%*d %d", &code) != 1 || code != 200) {
		MCA_DEBUG("CA update: proxy %s refused CONNECT (status %d)\n", proxy->host, code);
		goto fail;
	}
	return fd;

fail:
	close(fd);
	return -1;
}

/* Header value of NAME (case-insensitive) in the NUL-terminated header
 * block HDRS, copied into OUT. */
static int mca_header(const char *hdrs, const char *name, char *out, size_t outsize)
{
	size_t nlen = strlen(name), n;
	const char *p = strstr(hdrs, "\r\n");

	while (p && p[2]) {
		p += 2;
		if (!strncasecmp(p, name, nlen) && p[nlen] == ':') {
			const char *v = p + nlen + 1;
			while (*v == ' ' || *v == '\t')
				v++;
			n = strcspn(v, "\r\n");
			while (n > 0 && (v[n - 1] == ' ' || v[n - 1] == '\t'))
				n--;
			if (n >= outsize)
				n = outsize - 1;
			memcpy(out, v, n);
			out[n] = 0;
			return 0;
		}
		p = strstr(p, "\r\n");
	}
	return -1;
}

/* Whether the chunked body in B (LEN bytes, NUL-terminated) is complete:
 * 1 yes, 0 not yet, -1 malformed. */
static int mca_chunked_complete(const char *b, size_t len)
{
	size_t pos = 0;

	for (;;) {
		const char *eol;
		char *end;
		unsigned long long size;

		if (pos >= len)
			return 0;
		if (!isxdigit((unsigned char) b[pos]))
			return -1;
		if (!(eol = mca_find(b + pos, len - pos, "\r\n")))
			return 0;
		size = strtoull(b + pos, &end, 16);
		if (end > eol || size > MCA_MAX_BYTES)
			return -1;
		pos = (size_t) (eol - b) + 2;
		if (size == 0) /* last chunk; the trailer section ends with an empty line */
			return (len - pos >= 2 && b[pos] == '\r' && b[pos + 1] == '\n')
				|| mca_find(b + pos, len - pos, "\r\n\r\n") ? 1 : 0;
		if (len - pos < size + 2)
			return 0;
		pos += (size_t) size + 2;
	}
}

/* Decode a complete chunked body in place. */
static int mca_dechunk(char *buf, size_t len, size_t *outlen)
{
	size_t src = 0, dst = 0, size;
	char *end;

	for (;;) {
		if (src >= len || !isxdigit((unsigned char) buf[src]))
			return -1;
		size = strtoul(buf + src, &end, 16);
		if (!(end = strstr(end, "\r\n")) || (size_t) (end - buf) > len)
			return -1;
		src = (size_t) (end - buf) + 2;
		if (size == 0)
			break;
		if (size > len - src || len - src - size < 2)
			return -1;
		memmove(buf + dst, buf + src, size);
		dst += size;
		src += size;
		if (buf[src] != '\r' || buf[src + 1] != '\n')
			return -1;
		src += 2;
	}
	buf[dst] = 0;
	*outlen = dst;
	return 0;
}

/*
 * GnuTLS transport with an absolute deadline.  SO_RCVTIMEO and GnuTLS' own
 * timeouts only limit idle time between bytes, and GnuTLS keeps reading
 * until a whole record (up to 16 KiB) has arrived - a peer trickling bytes
 * could hold a record for hours.  These functions refuse to wait past the
 * deadline in any read or write.
 */
typedef struct {
	int fd;
	long long deadline;
} mca_transport_t;

static int mca_wait_fd(const mca_transport_t *t, short events, int max_ms)
{
	struct pollfd pfd;
	int ms = mca_left_ms(t->deadline), rc;

	if (max_ms >= 0 && max_ms < ms)
		ms = max_ms;
	if (ms <= 0)
		return 0;
	pfd.fd = t->fd;
	pfd.events = events;
	do {
		pfd.revents = 0;
		rc = poll(&pfd, 1, ms);
	} while (rc < 0 && errno == EINTR && (ms = mca_left_ms(t->deadline)) > 0);
	return rc;
}

static ssize_t mca_pull(gnutls_transport_ptr_t ptr, void *buf, size_t n)
{
	const mca_transport_t *t = ptr;
	int rc = mca_wait_fd(t, POLLIN, -1);

	if (rc == 0) {
		errno = EAGAIN;
		return -1;
	}
	if (rc < 0)
		return -1;
	return recv(t->fd, buf, n, 0);
}

static int mca_pull_timeout(gnutls_transport_ptr_t ptr, unsigned int ms)
{
	return mca_wait_fd(ptr, POLLIN, ms == GNUTLS_INDEFINITE_TIMEOUT ? -1 : ms > INT_MAX ? INT_MAX : (int) ms);
}

static ssize_t mca_push(gnutls_transport_ptr_t ptr, const void *buf, size_t n)
{
	const mca_transport_t *t = ptr;
	int rc = mca_wait_fd(t, POLLOUT, -1);

	if (rc == 0) {
		errno = EAGAIN;
		return -1;
	}
	if (rc < 0)
		return -1;
#ifdef MSG_NOSIGNAL
	return send(t->fd, buf, n, MSG_NOSIGNAL);
#else
	return send(t->fd, buf, n, 0); /* SO_NOSIGPIPE is set on the socket */
#endif
}

static int mca_https_get(const mca_url_t *u, const char *if_modified_since,
	gnutls_certificate_credentials_t cred, mca_response_t *resp)
{
	gnutls_session_t s = NULL;
	mca_url_t proxy;
	char *auth = NULL, *req = NULL, *buf = NULL, *head = NULL, value[128];
	size_t len = 0, cap = 0, hdr_len = 0, blen;
	long long clen = -1, deadline = mca_now_ms() + MCA_TOTAL_TIMEOUT_MS;
	ssize_t n;
	int fd = -1, rc, use_proxy, ret = -1, chunked = 0, complete = 0, clean_close = 0;
	int v6 = strchr(u->host, ':') != NULL;
	struct in_addr v4addr;
	mca_transport_t tp;

	memset(resp, 0, sizeof(*resp));

	use_proxy = mca_proxy_for(u->host, &proxy, &auth);
	if (use_proxy < 0) {
		MCA_DEBUG("CA update: unsupported proxy setting\n");
		goto out;
	}
	fd = use_proxy ? mca_proxy_connect(&proxy, auth, u->host, u->port, deadline)
		: mca_tcp_connect(u->host, u->port, deadline);
	if (fd < 0)
		goto out;

	if (gnutls_init(&s, GNUTLS_CLIENT) < 0)
		goto out;
	if (gnutls_set_default_priority(s) < 0
		|| gnutls_credentials_set(s, GNUTLS_CRD_CERTIFICATE, cred) < 0)
		goto out;
	if (!v6 && inet_pton(AF_INET, u->host, &v4addr) != 1) /* no SNI for address literals */
		gnutls_server_name_set(s, GNUTLS_NAME_DNS, u->host, strlen(u->host));
	gnutls_session_set_verify_cert(s, u->host, 0);
	tp.fd = fd;
	tp.deadline = deadline;
	gnutls_transport_set_ptr(s, &tp);
	gnutls_transport_set_pull_function(s, mca_pull);
	gnutls_transport_set_pull_timeout_function(s, mca_pull_timeout);
	gnutls_transport_set_push_function(s, mca_push);

	/* The transport returns EAGAIN (GNUTLS_E_AGAIN) once the deadline has
	 * passed.  GnuTLS also returns GNUTLS_E_AGAIN after processing TLS 1.3
	 * post-handshake messages, so retry, but never beyond the deadline. */
	do {
		gnutls_handshake_set_timeout(s, (unsigned) mca_left_ms(deadline) + 1);
		rc = gnutls_handshake(s);
	} while (rc < 0 && !gnutls_error_is_fatal(rc) && mca_left_ms(deadline) > 0);
	if (rc < 0) {
		MCA_DEBUG("CA update: TLS handshake with %s failed: %s\n", u->host, gnutls_strerror(rc));
		if (rc == GNUTLS_E_CERTIFICATE_VERIFICATION_ERROR) {
			gnutls_datum_t txt = { NULL, 0 };
			unsigned status = gnutls_session_get_verify_cert_status(s);
			if (gnutls_certificate_verification_status_print(status, gnutls_certificate_type_get(s), &txt, 0) == 0) {
				MCA_DEBUG("CA update: %s\n", (char *) txt.data);
				gnutls_free(txt.data);
			}
		}
		goto out;
	}

	req = mca_printf(
		"GET %s HTTP/1.1\r\n"
		"Host: %s%s%s%s%s\r\n"
		"User-Agent: %s\r\n"
		"Accept: */*\r\n"
		"Accept-Encoding: identity\r\n"
		"%s%s%s"
		"Connection: close\r\n"
		"\r\n",
		u->path,
		v6 ? "[" : "", u->host, v6 ? "]" : "", strcmp(u->port, "443") ? ":" : "", strcmp(u->port, "443") ? u->port : "",
		MCA_USER_AGENT,
		if_modified_since ? "If-Modified-Since: " : "", if_modified_since ? if_modified_since : "", if_modified_since ? "\r\n" : "");
	if (!req)
		goto out;
	for (size_t off = 0, rlen = strlen(req); off < rlen; ) {
		if (mca_left_ms(deadline) <= 0)
			goto timeout;
		n = gnutls_record_send(s, req + off, rlen - off);
		if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED)
			continue;
		if (n <= 0)
			goto out;
		off += (size_t) n;
	}

	/* Read until the response is complete as announced by its framing
	 * (Content-Length or the last chunk): a server that ignores
	 * "Connection: close" must not hold us until the deadline, and data
	 * without framing counts only if the server closed TLS properly. */
	for (;;) {
		if (cap - len < 16384) {
			char *nb;
			if (cap >= MCA_MAX_BYTES + 65536) {
				MCA_DEBUG("CA update: response too large\n");
				goto out;
			}
			cap = cap ? cap * 2 : 262144;
			if (!(nb = realloc(buf, cap + 1)))
				goto out;
			buf = nb;
		}
		if (mca_left_ms(deadline) <= 0)
			goto timeout;
		n = gnutls_record_recv(s, buf + len, cap - len);
		if (n > 0) {
			len += (size_t) n;
			buf[len] = 0;
			while (!hdr_len) {
				const char *e = mca_find(buf, len, "\r\n\r\n");
				int st;
				size_t hl;

				if (!e)
					break;
				hl = (size_t) (e - buf) + 4;
				if (sscanf(buf, "HTTP/%*d.%*d %d", &st) == 1 && st >= 100 && st < 200 && st != 101) {
					/* interim response (100 Continue, 103 Early Hints): skip */
					memmove(buf, buf + hl, len - hl + 1);
					len -= hl;
					continue;
				}
				hdr_len = hl;
				if (!(head = malloc(hdr_len + 1)))
					goto out;
				memcpy(head, buf, hdr_len);
				head[hdr_len - 2] = 0; /* keep the CRLF ending the last header */
				if (sscanf(head, "HTTP/%*d.%*d %d", &resp->status) != 1) {
					MCA_DEBUG("CA update: malformed HTTP response\n");
					goto out;
				}
				if (mca_header(head, "Transfer-Encoding", value, sizeof(value)) == 0)
					chunked = strcasestr(value, "chunked") != NULL;
				else if (mca_header(head, "Content-Length", value, sizeof(value)) == 0) {
					char *e2;
					errno = 0;
					clen = (long long) strtoull(value, &e2, 10);
					if (!*value || *e2 || errno || clen < 0 || clen > MCA_MAX_BYTES) {
						MCA_DEBUG("CA update: invalid Content-Length '%s'\n", value);
						goto out;
					}
				}
			}
			if (!hdr_len) {
				if (len > MCA_MAX_HEADER_BYTES) {
					MCA_DEBUG("CA update: malformed HTTP response\n");
					goto out;
				}
				continue;
			}
			blen = len - hdr_len;
			if (blen > MCA_MAX_BYTES + 65536) { /* chunked or unframed */
				MCA_DEBUG("CA update: response too large\n");
				goto out;
			}
			if (resp->status != 200 || (clen >= 0 && (long long) blen >= clen)
				|| (chunked && mca_chunked_complete(buf + hdr_len, blen) != 0)) {
				complete = 1; /* for other statuses only the header matters */
				break;
			}
			continue;
		}
		if (n == 0) { /* TLS close_notify */
			clean_close = 1;
			break;
		}
		if (n == GNUTLS_E_PREMATURE_TERMINATION)
			break;
		if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED)
			continue;
		MCA_DEBUG("CA update: read error: %s\n", gnutls_strerror((int) n));
		goto out;
	}

	if (!head) {
		MCA_DEBUG("CA update: malformed HTTP response\n");
		goto out;
	}
	if (mca_header(head, "Last-Modified", value, sizeof(value)) == 0)
		snprintf(resp->last_modified, sizeof(resp->last_modified), "%s", value);

	if (resp->status == 200) {
		char *body = buf + hdr_len;

		blen = len - hdr_len;
		if (!complete && (clen >= 0 || chunked)) {
			MCA_DEBUG("CA update: incomplete body (%zu bytes received)\n", blen);
			goto out;
		}
		if (!complete && !clean_close) {
			MCA_DEBUG("CA update: connection closed without TLS close_notify, the body may be truncated\n");
			goto out;
		}
		if (chunked) {
			if (mca_dechunk(body, blen, &blen) != 0) {
				MCA_DEBUG("CA update: malformed chunked body\n");
				goto out;
			}
		} else if (clen >= 0) {
			blen = (size_t) clen; /* ignore anything after the announced body */
		}
		if (!(resp->body = malloc(blen + 1)))
			goto out;
		memcpy(resp->body, body, blen);
		resp->body[blen] = 0;
		resp->body_len = blen;
	}
	ret = 0;
	goto out;

timeout:
	MCA_DEBUG("CA update: no complete answer from %s within %d seconds\n", u->host, MCA_TOTAL_TIMEOUT_MS / 1000);
out:
	if (s) {
		gnutls_deinit(s);
	}
	if (fd >= 0)
		close(fd);
	free(auth);
	free(req);
	free(head);
	free(buf);
	return ret;
}

/* ------------------------------------------------------------ the refresh */

static int mca_env_disabled(void)
{
	const char *v = getenv("WGET_CA_AUTO_UPDATE");

	return v && (!strcmp(v, "0") || !strcasecmp(v, "no") || !strcasecmp(v, "off") || !strcasecmp(v, "false"));
}

static long mca_interval(void)
{
	const char *v = getenv("WGET_CA_UPDATE_INTERVAL");
	char *end;
	long h;

	if (v && *v) {
		h = strtol(v, &end, 10);
		if (!*end && h >= 0 && h <= 24L * 366)
			return h * 3600;
	}
	return MCA_DEFAULT_INTERVAL_HOURS * 3600L;
}

static int mca_recent(const char *stamp, time_t now, long seconds)
{
	time_t t = mca_mtime(stamp);

	return t && t <= now && now - t < seconds;
}

/* Consecutive failures recorded in the FAILED stamp (0 if none). */
static int mca_failures(const char *failed)
{
	char *data;
	size_t len;
	long n = 0;

	if (mca_read_file(failed, &data, &len, 64) == 0) {
		n = strtol(data, NULL, 10);
		free(data);
	} else if (mca_mtime(failed)) {
		n = 1; /* empty stamp */
	}
	return n < 0 ? 0 : n > 30 ? 30 : (int) n;
}

/* Retry delay after N consecutive failures: 1 h, 2 h, 4 h, ... at most 24 h. */
static long mca_backoff(int n)
{
	long s = MCA_BACKOFF_MIN_SECS;

	while (--n > 0 && s < MCA_BACKOFF_MAX_SECS)
		s *= 2;
	return s < MCA_BACKOFF_MAX_SECS ? s : MCA_BACKOFF_MAX_SECS;
}

static void mca_record_failure(const char *failed, long interval)
{
	char num[16];
	int n = mca_failures(failed) + 1;

	snprintf(num, sizeof(num), "%d\n", n);
	if (mca_write_atomic(failed, num, strlen(num)) != 0)
		mca_stamp(failed);
	if (interval > 0)
		MCA_DEBUG("CA update: failed; next attempt in %ld hour(s)\n", mca_backoff(n) / 3600);
	else
		MCA_DEBUG("CA update: failed; next attempt on the next run (WGET_CA_UPDATE_INTERVAL=0)\n");
}

static void mca_refresh(const char *cachedir, const char *cachefile, const char *snapshot)
{
	char *checked = mca_printf("%s/cacert.pem.checked", cachedir);
	char *failed = mca_printf("%s/cacert.pem.failed", cachedir);
	char *lastmod = mca_printf("%s/cacert.pem.lastmod", cachedir);
	char *lockfile = mca_printf("%s/.lock", cachedir);
	char *base = NULL, *ims = NULL, *lm_data = NULL;
	const char *url = getenv("WGET_CA_UPDATE_URL");
	gnutls_certificate_credentials_t cred = NULL;
	mca_response_t resp = { 0, NULL, 0, { 0 } };
	mca_info_t binfo = { 0, 0 }, sinfo, ninfo;
	long interval = mca_interval();
	time_t now = time(NULL), cache_mtime;
	mca_url_t u;
	size_t lm_len;
	int lockfd = -1, ok = 0, have_snapshot, rc;

	if (!checked || !failed || !lastmod || !lockfile)
		goto out;

	if (interval > 0 && (mca_recent(checked, now, interval)
		|| mca_recent(failed, now, mca_backoff(mca_failures(failed)))))
		goto out;

	/* one refresher at a time; concurrent wget processes just go ahead */
	if ((lockfd = open(lockfile, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600)) < 0
		|| flock(lockfd, LOCK_EX | LOCK_NB) != 0)
		goto out;
	if (interval > 0 && mca_recent(checked, time(NULL), interval))
		goto out; /* refreshed by another process meanwhile */

	if (!url || !*url)
		url = MCA_DEFAULT_URL;
	if (mca_parse_https_url(url, &u) != 0) {
		MCA_DEBUG("CA update: invalid URL '%s' (https:// required)\n", url);
		mca_record_failure(failed, interval);
		goto out;
	}

	have_snapshot = mca_info_file(snapshot, 0, 0, &sinfo) == 0;
	base = mca_choose(cachefile, snapshot, &binfo);

	/* Conditional GET only while the cached copy is the one in use and was
	 * downloaded less than a week ago: a periodic full download makes sure
	 * a forged Last-Modified cannot pin an old copy for long. */
	cache_mtime = mca_mtime(cachefile);
	if (base && !strcmp(base, cachefile) && cache_mtime && cache_mtime <= now
		&& now - cache_mtime < MCA_FULL_REFRESH_SECS
		&& mca_read_file(lastmod, &lm_data, &lm_len, 1024) == 0) {
		lm_data[strcspn(lm_data, "\r\n")] = 0;
		if (*lm_data)
			ims = lm_data;
	}

	if (gnutls_certificate_allocate_credentials(&cred) < 0)
		goto out;
	gnutls_certificate_set_x509_system_trust(cred); /* the Keychain */
	if (base)
		gnutls_certificate_set_x509_trust_file(cred, base, GNUTLS_X509_FMT_PEM);

	MCA_DEBUG("CA update: checking %s%s%s%s\n", url,
		ims ? " (if modified since " : "", ims ? ims : "", ims ? ")" : "");

	if (mca_https_get(&u, ims, cred, &resp) != 0) {
		mca_record_failure(failed, interval);
		goto out;
	}

	if (resp.status == 304) {
		MCA_DEBUG("CA update: bundle unchanged\n");
		ok = 1;
	} else if (resp.status == 200) {
		rc = mca_info_mem(resp.body, resp.body_len, 1, time(NULL) + MCA_MAX_FUTURE_SECS, &ninfo);
		if (rc == -2) {
			MCA_DEBUG("CA update: downloaded bundle is dated in the future; rejected\n");
		} else if (rc != 0) {
			MCA_DEBUG("CA update: downloaded data is not a valid Mozilla CA bundle\n");
		} else if (have_snapshot && ninfo.asof < sinfo.asof) {
			/* never go back behind the data wget2 shipped with */
			MCA_DEBUG("CA update: server offers an older bundle than the one shipped with wget2; ignored\n");
			ok = 1;
		} else if (mca_write_atomic(cachefile, resp.body, resp.body_len) != 0) {
			MCA_DEBUG("CA update: cannot write %s: %s\n", cachefile, strerror(errno));
		} else {
			if (resp.last_modified[0])
				mca_write_atomic(lastmod, resp.last_modified, strlen(resp.last_modified));
			else
				unlink(lastmod);
			MCA_DEBUG("CA update: stored %d certificates in %s\n", ninfo.ncerts, cachefile);
			ok = 1;
		}
	} else {
		MCA_DEBUG("CA update: server answered with status %d\n", resp.status);
	}

	if (ok) {
		mca_stamp(checked);
		unlink(failed);
	} else {
		mca_record_failure(failed, interval);
	}

out:
	if (cred)
		gnutls_certificate_free_credentials(cred);
	if (lockfd >= 0)
		close(lockfd); /* releases the flock */
	free(resp.body);
	free(lm_data);
	free(base);
	free(checked);
	free(failed);
	free(lastmod);
	free(lockfile);
}

/* Path of the CA bundle to load for "--ca-certificate=system" (the default),
 * refreshing the per-user copy first if NETWORK_ALLOWED and it is due.
 * Returns NULL if no bundle is available (the Keychain is still used). */
static const char *wget_macos_ca_bundle_path(int network_allowed)
{
	static char *chosen;
	char *snapshot = MCA_SNAPSHOT_PATH();
	char *cachedir = mca_cache_dir();
	char *cachefile = cachedir ? mca_printf("%s/cacert.pem", cachedir) : NULL;
	mca_info_t info;
	char *best;

	if (network_allowed && cachefile) {
		if (mca_env_disabled())
			MCA_DEBUG("CA update: disabled by WGET_CA_AUTO_UPDATE\n");
		else
			mca_refresh(cachedir, cachefile, snapshot);
	}

	if ((best = mca_choose(cachefile, snapshot, &info))) {
		char date[32];
		struct tm tm;
		strftime(date, sizeof(date), "%Y-%m-%d", gmtime_r(&info.asof, &tm));
		MCA_DEBUG("Using Mozilla CA bundle %s (data as of %s, %d certificates)\n", best, date, info.ncerts);
	} else {
		MCA_DEBUG("No Mozilla CA bundle available, using the macOS Keychain only\n");
	}

	free(chosen);
	chosen = best;
	free(snapshot);
	free(cachefile);
	free(cachedir);
	return chosen;
}
