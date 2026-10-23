#!/usr/bin/env python3
"""GnuTLS 3.8.13: honour macOS Keychain trust settings in the system trust store.

Upstream's macOS add_system_trust() (lib/system/certs.c) takes every
certificate that has trust settings in the user, admin or system domain and
adds it as a trust anchor.  That ignores what the settings say:

  * a certificate the user or an administrator marked "Never Trust" becomes
    a trusted root;
  * settings restricted to other policies (S/MIME, code signing, ...) or to
    one host name are treated as unrestricted SSL trust;
  * a failing SecItemExport() calls CFRelease(NULL), which crashes.

The replacement evaluates each certificate's trust settings for SSL server
trust the way trustd does (Security: trustd/SecCertificateSource.c,
SecPolicyServer.c):

  * admin settings, if a certificate has any, are used and the user's are
    ignored; otherwise the user's settings are used; only if those give no
    decision do the system settings count (a system root without settings
    is trusted);
  * within one array of usage constraints the first entry that applies to
    SSL server trust decides, also when its result is "Unspecified";
  * "Trust Root" makes only a self-signed certificate an anchor, "Trust As
    Root" only a certificate that is not self-signed; an empty array means
    "always trust" for a self-signed certificate.

Trusted certificates become anchors, denied ones go on the trust list's block
list.  gnutls-3.8.13-trust-list-blocklist.py makes that block list stick, so
a denied CA stays distrusted even though the Mozilla bundle that wget2 loads
afterwards contains it.

Deliberately stricter than trustd, because an anchor here applies to every
host and to all of wget: an entry limited to some host names, applications
or key usages never makes a certificate trusted, and if such a limited entry
says "Deny" (and comes before the entry that decides) the certificate is
denied everywhere; an entry whose result is not a number decides "no trust"
instead of "Trust Root".
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

START = "#elif defined(__APPLE__) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070\n"
END = "#else\n\n#define add_system_trust(x, y, z) GNUTLS_E_UNIMPLEMENTED_FEATURE\n"

NEW = r'''#elif defined(__APPLE__) && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
/*
 * macOS: trust anchors from the Keychain trust settings (patched for the
 * portable wget2 bundle build; see gnutls-3.8.13-macos-keychain-trust.py).
 *
 * Each certificate that has trust settings is evaluated for SSL server trust
 * like trustd does: admin settings (if any) replace the user's, the system
 * settings count only when those give no decision, and within an array of
 * usage constraints the first applicable entry decides.  Entries limited to
 * host names, applications or key usages never create an anchor, and a Deny
 * among them denies the certificate everywhere.  Trusted certificates become
 * trust anchors, denied ones go on the block list.
 */

#define GNUTLS_APPLE_TS_UNSPECIFIED 0
#define GNUTLS_APPLE_TS_TRUST 1
#define GNUTLS_APPLE_TS_DENY 2

/* usage-constraint keys that are not in the public SDK headers
 * (Security: trust/headers/SecTrustSettingsPriv.h) */
#define GNUTLS_APPLE_TS_POLICY_NAME CFSTR("kSecTrustSettingsPolicyName")
#define GNUTLS_APPLE_TS_POLICY_OPTIONS CFSTR("kSecTrustSettingsPolicyOptions")
#define GNUTLS_APPLE_POLICY_NAME_SSL_SERVER CFSTR("sslServer")

static void apple_log_status(const char *what, OSStatus status)
{
	char buf[256] = "";
	CFStringRef s = SecCopyErrorMessageString(status, NULL);

	if (s != NULL) {
		CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
		CFRelease(s);
	}
	_gnutls_debug_log("%s: OSStatus %d: %s\n", what, (int)status, buf);
}

/* the policy of a usage constraint (a SecPolicyRef, or an OID string) is
 * the SSL policy */
static int apple_policy_is_ssl(CFTypeRef policy)
{
	CFDictionaryRef props;
	CFTypeRef oid;
	int ret = 0;

	if (policy == NULL)
		return 0;
	if (CFGetTypeID(policy) == CFStringGetTypeID())
		return CFEqual(policy, kSecPolicyAppleSSL);
	if (CFGetTypeID(policy) != SecPolicyGetTypeID())
		return 0;
	props = SecPolicyCopyProperties((SecPolicyRef)policy);
	if (props == NULL)
		return 0;
	oid = CFDictionaryGetValue(props, kSecPolicyOid);
	if (oid != NULL && CFEqual(oid, kSecPolicyAppleSSL))
		ret = 1;
	CFRelease(props);
	return ret;
}

static int apple_get_sint32(CFTypeRef v, SInt32 *out)
{
	return v != NULL && CFGetTypeID(v) == CFNumberGetTypeID() &&
	       CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, out);
}

static int apple_get_sint64(CFTypeRef v, SInt64 *out)
{
	return v != NULL && CFGetTypeID(v) == CFNumberGetTypeID() &&
	       CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out);
}

/* SSL server trust from one array of usage constraints. */
static int apple_eval_constraints(CFArrayRef settings, int self_signed)
{
	CFIndex i, n = CFArrayGetCount(settings);

	if (n == 0) /* "always trust" */
		return self_signed ? GNUTLS_APPLE_TS_TRUST :
				     GNUTLS_APPLE_TS_UNSPECIFIED;

	for (i = 0; i < n; i++) {
		CFTypeRef d = CFArrayGetValueAtIndex(settings, i);
		CFTypeRef v;
		SInt32 result = kSecTrustSettingsResultTrustRoot;
		SInt64 usage;
		int limited = 0;

		if (d == NULL || CFGetTypeID(d) != CFDictionaryGetTypeID())
			continue;

		/* entries for other policies do not apply */
		v = CFDictionaryGetValue((CFDictionaryRef)d,
					 kSecTrustSettingsPolicy);
		if (v != NULL && !apple_policy_is_ssl(v))
			continue;
		v = CFDictionaryGetValue((CFDictionaryRef)d,
					 GNUTLS_APPLE_TS_POLICY_NAME);
		if (v != NULL &&
		    !(CFGetTypeID(v) == CFStringGetTypeID() &&
		      CFEqual(v, GNUTLS_APPLE_POLICY_NAME_SSL_SERVER)))
			continue;
		/* trustd never lets an entry with policy options match */
		if (CFDictionaryContainsKey((CFDictionaryRef)d,
					    GNUTLS_APPLE_TS_POLICY_OPTIONS))
			continue;

		/* limited to some host names, applications or key usages (an
		 * anchor needs exactly "sign certificates", or "any") */
		if (CFDictionaryContainsKey((CFDictionaryRef)d,
					    kSecTrustSettingsPolicyString) ||
		    CFDictionaryContainsKey((CFDictionaryRef)d,
					    kSecTrustSettingsApplication))
			limited = 1;
		v = CFDictionaryGetValue((CFDictionaryRef)d,
					 kSecTrustSettingsKeyUsage);
		if (v != NULL &&
		    (!apple_get_sint64(v, &usage) ||
		     ((UInt32)usage != (UInt32)kSecTrustSettingsKeyUseAny &&
		      (UInt32)usage != (UInt32)kSecTrustSettingsKeyUseSignCert)))
			limited = 1;

		/* no result means "Trust Root" */
		v = CFDictionaryGetValue((CFDictionaryRef)d,
					 kSecTrustSettingsResult);
		if (v != NULL && !apple_get_sint32(v, &result))
			result = kSecTrustSettingsResultInvalid;

		if (limited) {
			if (result == kSecTrustSettingsResultDeny)
				return GNUTLS_APPLE_TS_DENY;
			continue;
		}

		/* the first applicable entry decides */
		if (result == kSecTrustSettingsResultDeny)
			return GNUTLS_APPLE_TS_DENY;
		if (result == kSecTrustSettingsResultTrustRoot)
			return self_signed ? GNUTLS_APPLE_TS_TRUST :
					     GNUTLS_APPLE_TS_UNSPECIFIED;
		if (result == kSecTrustSettingsResultTrustAsRoot)
			return self_signed ? GNUTLS_APPLE_TS_UNSPECIFIED :
					     GNUTLS_APPLE_TS_TRUST;
		return GNUTLS_APPLE_TS_UNSPECIFIED; /* Unspecified, invalid */
	}
	return GNUTLS_APPLE_TS_UNSPECIFIED;
}

/* SSL server trust of CERT from the settings in DOMAIN; *found tells
 * whether the domain holds trust settings for it at all. */
static int apple_ssl_trust(SecCertificateRef cert,
			   SecTrustSettingsDomain domain, int self_signed,
			   int *found)
{
	CFArrayRef settings = NULL;
	OSStatus status;
	int decision;

	*found = 0;
	status = SecTrustSettingsCopyTrustSettings(cert, domain, &settings);
	if (status != errSecSuccess || settings == NULL) {
		if (settings != NULL)
			CFRelease(settings);
		return GNUTLS_APPLE_TS_UNSPECIFIED;
	}
	*found = 1;
	decision = apple_eval_constraints(settings, self_signed);
	CFRelease(settings);
	return decision;
}

static int apple_is_self_signed(const gnutls_datum_t *der)
{
	gnutls_x509_crt_t crt;
	int ret = 0;

	if (gnutls_x509_crt_init(&crt) < 0)
		return 0;
	if (gnutls_x509_crt_import(crt, der, GNUTLS_X509_FMT_DER) >= 0)
		ret = gnutls_x509_crt_check_issuer(crt, crt) != 0;
	gnutls_x509_crt_deinit(crt);
	return ret;
}

static int add_system_trust(gnutls_x509_trust_list_t list,
			    unsigned int tl_flags, unsigned int tl_vflags)
{
	enum { TS_USER, TS_ADMIN, TS_SYSTEM, TS_NDOMAINS };
	static const SecTrustSettingsDomain domain[TS_NDOMAINS] = {
		kSecTrustSettingsDomainUser, kSecTrustSettingsDomainAdmin,
		kSecTrustSettingsDomainSystem
	};
	CFArrayRef certs[TS_NDOMAINS] = { NULL, NULL, NULL };
	CFMutableSetRef members[TS_NDOMAINS] = { NULL, NULL, NULL };
	CFMutableSetRef seen = NULL;
	int r = 0, denied = 0, ret = 0;
	size_t d;
	CFIndex i, n;
	OSStatus status;

	for (d = 0; d < TS_NDOMAINS; d++) {
		status = SecTrustSettingsCopyCertificates(domain[d], &certs[d]);
		if (status == errSecSuccess && certs[d] != NULL)
			continue;
		if (certs[d] != NULL)
			CFRelease(certs[d]);
		certs[d] = NULL;
		if (status != errSecNoTrustSettings)
			apple_log_status("SecTrustSettingsCopyCertificates", status);
	}
	/* without the system roots the user's and administrator's decisions
	 * (above all "Never Trust") still have to be applied */
	if (certs[TS_SYSTEM] == NULL)
		_gnutls_debug_log("macOS Keychain: system roots unavailable\n");

	/* DER of the certificates listed in each domain */
	for (d = 0; d < TS_NDOMAINS; d++) {
		if (certs[d] == NULL)
			continue;
		members[d] = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
		if (members[d] == NULL) {
			ret = gnutls_assert_val(GNUTLS_E_MEMORY_ERROR);
			goto cleanup;
		}
		n = CFArrayGetCount(certs[d]);
		for (i = 0; i < n; i++) {
			SecCertificateRef cert = (SecCertificateRef)
				CFArrayGetValueAtIndex(certs[d], i);
			CFDataRef der = SecCertificateCopyData(cert);
			if (der != NULL) {
				CFSetAddValue(members[d], der);
				CFRelease(der);
			}
		}
	}

	seen = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
	if (seen == NULL) {
		ret = gnutls_assert_val(GNUTLS_E_MEMORY_ERROR);
		goto cleanup;
	}

	for (d = 0; d < TS_NDOMAINS; d++) {
		if (certs[d] == NULL)
			continue;
		n = CFArrayGetCount(certs[d]);
		for (i = 0; i < n; i++) {
			SecCertificateRef cert = (SecCertificateRef)
				CFArrayGetValueAtIndex(certs[d], i);
			CFDataRef der = SecCertificateCopyData(cert);
			int decision = GNUTLS_APPLE_TS_UNSPECIFIED;
			int found = 0, self_signed;
			gnutls_datum_t datum;

			if (der == NULL)
				continue;
			if (CFSetContainsValue(seen, der)) {
				CFRelease(der);
				continue;
			}
			CFSetAddValue(seen, der);
			datum.data = (unsigned char *)CFDataGetBytePtr(der);
			datum.size = (unsigned int)CFDataGetLength(der);
			self_signed = apple_is_self_signed(&datum);

			/* admin settings replace the user's (as in trustd) */
			if (members[TS_ADMIN] != NULL &&
			    CFSetContainsValue(members[TS_ADMIN], der))
				decision = apple_ssl_trust(cert,
							   domain[TS_ADMIN],
							   self_signed, &found);
			if (!found && members[TS_USER] != NULL &&
			    CFSetContainsValue(members[TS_USER], der))
				decision = apple_ssl_trust(cert, domain[TS_USER],
							   self_signed, &found);
			/* the system roots count when there is no decision;
			 * one without readable settings is trusted */
			if (decision == GNUTLS_APPLE_TS_UNSPECIFIED &&
			    members[TS_SYSTEM] != NULL &&
			    CFSetContainsValue(members[TS_SYSTEM], der)) {
				decision = apple_ssl_trust(cert,
							   domain[TS_SYSTEM],
							   self_signed, &found);
				if (!found)
					decision = GNUTLS_APPLE_TS_TRUST;
			}

			if (decision == GNUTLS_APPLE_TS_TRUST) {
				if (gnutls_x509_trust_list_add_trust_mem(
					    list, &datum, NULL, GNUTLS_X509_FMT_DER,
					    tl_flags, tl_vflags) > 0)
					r++;
			} else if (decision == GNUTLS_APPLE_TS_DENY) {
				if (gnutls_x509_trust_list_remove_trust_mem(
					    list, &datum, GNUTLS_X509_FMT_DER) >= 0)
					denied++;
			}
			CFRelease(der);
		}
	}

	_gnutls_debug_log("macOS Keychain: %d trusted, %d distrusted certificates\n",
			  r, denied);

#ifdef DEFAULT_BLOCKLIST_FILE
	if (gnutls_x509_trust_list_remove_trust_file(
		    list, DEFAULT_BLOCKLIST_FILE, GNUTLS_X509_FMT_PEM) < 0) {
		_gnutls_debug_log("Could not load blocklist file '%s'\n",
				  DEFAULT_BLOCKLIST_FILE);
	}
#endif

	ret = r;

cleanup:
	for (d = 0; d < TS_NDOMAINS; d++) {
		if (certs[d] != NULL)
			CFRelease(certs[d]);
		if (members[d] != NULL)
			CFRelease(members[d]);
	}
	if (seen != NULL)
		CFRelease(seen);
	return ret;
}
'''


def apply(src):
    certs_c = os.path.join(src, "lib", "system", "certs.c")
    patchlib.require(certs_c, "#include <Security/Security.h>", "Security.framework include")
    patchlib.replace_between(certs_c, START, END, NEW, "macOS Keychain trust settings")


if __name__ == "__main__":
    patchlib.main(apply)
