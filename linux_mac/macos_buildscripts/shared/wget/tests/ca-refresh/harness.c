/* Standalone harness for wget_macos_ca.c (see run.sh). */
#define _GNU_SOURCE
#define WGET_MACOS_CA_STANDALONE
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MCA_DEBUG(...) fprintf(stderr, __VA_ARGS__)
#define MCA_SNAPSHOT_PATH() (getenv("TEST_SNAPSHOT") ? strdup(getenv("TEST_SNAPSHOT")) : NULL)
#define MCA_USER_AGENT "wget2-ca-refresh-test"
/* the tests run as any user; TEST_AS_ROOT simulates root */
#define MCA_IS_ROOT() (getenv("TEST_AS_ROOT") != NULL)
#define MCA_ROOT_HOME() getenv("TEST_ROOT_HOME")

/* TEST_GAI_DELAY=<seconds> makes name lookups hang that long */
static int test_getaddrinfo(const char *node, const char *service,
	const struct addrinfo *hints, struct addrinfo **res)
{
	const char *d = getenv("TEST_GAI_DELAY");

	if (d)
		sleep((unsigned) atoi(d));
	return getaddrinfo(node, service, hints, res);
}
#define getaddrinfo test_getaddrinfo

#include "wget_macos_ca.c"

int main(int argc, char **argv)
{
	const char *p;

	gnutls_global_init();
	p = wget_macos_ca_bundle_path(argc > 1 ? atoi(argv[1]) : 1);
	printf("RESULT %s\n", p ? p : "(none)");
	gnutls_global_deinit();
	return 0;
}
