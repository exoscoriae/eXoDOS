#!/usr/bin/env python3
"""GnuTLS 3.8.13: make the trust list's block list stick.

gnutls_x509_trust_list_remove_cas() (used for "Never Trust" Keychain
settings, see gnutls-3.8.13-macos-keychain-trust.py, and for
DEFAULT_BLOCKLIST_FILE) removes a certificate from the trusted list and puts
it on the block list.  Upstream, that does not hold:

  * a CA bundle loaded afterwards (wget2 loads the system trust first, then
    the Mozilla bundle) simply adds the certificate back as a trust anchor;
  * the block list is only compared with the chain the peer sent, and GnuTLS
    drops a self-signed root from that chain before looking up the anchor,
    so the re-added root is used without being checked;
  * the comparison is byte-exact, so a re-issued certificate for the same
    CA (same subject and key, new validity dates) is not blocked.

With this patch:

  * gnutls_x509_trust_list_add_cas() does not use certificates on the block
    list as anchors.  Ownership is unchanged: such a certificate is parked in
    the list and released by gnutls_x509_trust_list_deinit() exactly when a
    trusted one would be (all != 0), so callers see the same lifetime rules;
  * gnutls_x509_trust_list_remove_cas() removes every trusted certificate
    with the same subject and public key, not only identical bytes, in every
    hash bucket (subjects compare equal across string encodings);
  * the block-list check during verification also matches subject + key.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

# ---- lib/x509/verify-high.h: storage for parked certificates
STRUCT_OLD = """	gnutls_x509_crt_t *keep_certs;
	unsigned int keep_certs_size;
"""

STRUCT_NEW = """	gnutls_x509_crt_t *keep_certs;
	unsigned int keep_certs_size;

	/* wget2 macOS bundle: distrusted certificates passed to add_cas(); not
	 * used, but owned (and released) like the trusted ones */
	gnutls_x509_crt_t *skipped_cas;
	unsigned int skipped_cas_size;
"""

# ---- lib/x509/verify-high.c
DEINIT_OLD = """	gnutls_free(list->x509_rdn_sequence.data);
	gnutls_free(list->node);
	gnutls_free(list->pkcs11_token);
	gnutls_free(list);
}
"""

DEINIT_NEW = """	if (all) {
		for (j = 0; j < list->skipped_cas_size; j++)
			gnutls_x509_crt_deinit(list->skipped_cas[j]);
	}
	gnutls_free(list->skipped_cas);

	gnutls_free(list->x509_rdn_sequence.data);
	gnutls_free(list->node);
	gnutls_free(list->pkcs11_token);
	gnutls_free(list);
}
"""

HELPER = r'''/* wget2 macOS bundle (gnutls-3.8.13-trust-list-blocklist.py): CRT is
 * distrusted when the block list holds it or a certificate for the same CA,
 * i.e. with the same subject and public key. */
static unsigned trust_list_is_distrusted(gnutls_x509_trust_list_t list,
					 gnutls_x509_crt_t crt)
{
	unsigned j;

	for (j = 0; j < list->distrusted_size; j++) {
		if (gnutls_x509_crt_equals(crt, list->distrusted[j]) != 0 ||
		    _gnutls_check_if_same_key(crt, list->distrusted[j], 1) != 0)
			return 1;
	}
	return 0;
}

'''

ADD_CAS_DOC = "/**\n * gnutls_x509_trust_list_add_cas:\n"

ADD_OLD = """	for (i = 0; i < clist_size; i++) {
		exists = 0;
		hash = hash_pjw_bare(clist[i]->raw_dn.data,
				     clist[i]->raw_dn.size);
		hash %= list->size;

		/* avoid duplicates */
"""

ADD_NEW = """	for (i = 0; i < clist_size; i++) {
		exists = 0;
		hash = hash_pjw_bare(clist[i]->raw_dn.data,
				     clist[i]->raw_dn.size);
		hash %= list->size;

		/* never (re-)add a certificate that was explicitly distrusted;
		 * keep it with the same ownership as a trusted one */
		if (trust_list_is_distrusted(list, clist[i])) {
			gnutls_x509_crt_t *sk;

			_gnutls_debug_log(
				"trust list: not adding a distrusted certificate\\n");
			if (unlikely(INT_ADD_OVERFLOW(list->skipped_cas_size,
						      1))) {
				gnutls_assert();
				return i;
			}
			sk = _gnutls_reallocarray(list->skipped_cas,
						  list->skipped_cas_size + 1,
						  sizeof(list->skipped_cas[0]));
			if (sk == NULL) {
				gnutls_assert();
				return i;
			}
			list->skipped_cas = sk;
			list->skipped_cas[list->skipped_cas_size++] = clist[i];
			continue;
		}

		/* avoid duplicates */
"""

REMOVE_OLD = """	int r = 0;
	unsigned j, i;
	size_t hash;

	for (i = 0; i < clist_size; i++) {
		hash = hash_pjw_bare(clist[i]->raw_dn.data,
				     clist[i]->raw_dn.size);
		hash %= list->size;

		for (j = 0; j < list->node[hash].trusted_ca_size; j++) {
			if (gnutls_x509_crt_equals(
				    clist[i],
				    list->node[hash].trusted_cas[j]) != 0) {
				gnutls_x509_crt_deinit(
					list->node[hash].trusted_cas[j]);
				list->node[hash].trusted_cas[j] =
					list->node[hash].trusted_cas
						[list->node[hash]
							 .trusted_ca_size -
						 1];
				list->node[hash].trusted_ca_size--;
				r++;
				break;
			}
		}
"""

REMOVE_NEW = """	int r = 0;
	unsigned j, i, h;

	for (i = 0; i < clist_size; i++) {
		/* remove every trusted certificate of this CA (same bytes, or
		 * same subject and key, e.g. a re-issued root); subjects that
		 * differ only in string encoding hash differently, so look in
		 * every bucket */
		for (h = 0; h < list->size; h++) {
			for (j = 0; j < list->node[h].trusted_ca_size;) {
				gnutls_x509_crt_t ca =
					list->node[h].trusted_cas[j];

				if (gnutls_x509_crt_equals(clist[i], ca) == 0 &&
				    _gnutls_check_if_same_key(clist[i], ca,
							      1) == 0) {
					j++;
					continue;
				}
				gnutls_x509_crt_deinit(ca);
				list->node[h].trusted_cas[j] =
					list->node[h].trusted_cas
						[list->node[h].trusted_ca_size -
						 1];
				list->node[h].trusted_ca_size--;
				r++;
			}
		}
"""

BLOCK_OLD = """	for (i = 0; i < cert_list_size; i++) {
		for (j = 0; j < blocklist_size; j++) {
			if (gnutls_x509_crt_equals(cert_list[i],
						   blocklist[j]) != 0) {
				return 1;
			}
		}
	}
"""

BLOCK_NEW = """	for (i = 0; i < cert_list_size; i++) {
		for (j = 0; j < blocklist_size; j++) {
			if (gnutls_x509_crt_equals(cert_list[i],
						   blocklist[j]) != 0 ||
			    _gnutls_check_if_same_key(cert_list[i],
						      blocklist[j], 1) != 0) {
				return 1;
			}
		}
	}
"""


def apply(src):
    vh = os.path.join(src, "lib", "x509", "verify-high.c")
    vhh = os.path.join(src, "lib", "x509", "verify-high.h")
    patchlib.require(vh, "_gnutls_check_if_same_key(", "same-key helper is available")
    patchlib.replace_once(vhh, STRUCT_OLD, STRUCT_NEW, "trust list: storage for distrusted CAs")
    patchlib.replace_once(vh, DEINIT_OLD, DEINIT_NEW, "trust list deinit releases distrusted CAs")
    patchlib.replace_once(vh, ADD_CAS_DOC, HELPER + ADD_CAS_DOC, "distrusted-certificate helper")
    patchlib.replace_once(vh, ADD_OLD, ADD_NEW, "add_cas does not use distrusted certificates")
    patchlib.replace_once(vh, REMOVE_OLD, REMOVE_NEW, "remove_cas removes every certificate of the CA")
    patchlib.replace_once(vh, BLOCK_OLD, BLOCK_NEW, "block-list check matches subject and key")


if __name__ == "__main__":
    patchlib.main(apply)
