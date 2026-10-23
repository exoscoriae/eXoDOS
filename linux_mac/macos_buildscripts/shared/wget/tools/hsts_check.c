/* Sanity check for the generated hsts.dafsa, using libhsts exactly the way
 * wget2 does (src/options.c, src/wget.c). */
#include <stdio.h>
#include <libhsts.h>

static int expect(hsts_t *h, const char *host, int preloaded)
{
	int found = hsts_search(h, host, 0, NULL) == HSTS_SUCCESS;

	if (found != preloaded) {
		fprintf(stderr, "hsts_check: %s: expected %s\n", host, preloaded ? "preloaded" : "not preloaded");
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	hsts_t *h = NULL;
	int rc, bad = 0;

	if (argc != 2) {
		fprintf(stderr, "usage: hsts_check FILE\n");
		return 2;
	}
	if ((rc = hsts_load_file(argv[1], &h)) != HSTS_SUCCESS) {
		fprintf(stderr, "hsts_check: cannot load %s (%d)\n", argv[1], rc);
		return 2;
	}
	bad += expect(h, "accounts.google.com", 1);
	bad += expect(h, "some-host.dev", 1);         /* .dev is preloaded with subdomains */
	bad += expect(h, "example.com", 0);
	bad += expect(h, "wget2-not-preloaded.example", 0);
	hsts_free(h);
	return bad ? 1 : 0;
}
