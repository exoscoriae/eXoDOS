#!/usr/bin/env python3
"""wget2 2.3.0: integration with the self-contained macOS application bundle.

Apply after wget2-2.3.0-backports.py.  Everything added is guarded by
__APPLE__, so the patched tree still builds unchanged elsewhere.

  * copies wget_macos_bundle.h / wget_macos_ca.c into the tree
  * translations are loaded from wget.app/Contents/Resources/locale
  * "--ca-certificate=system" (the default) loads the newest of the bundled
    and the auto-updated Mozilla CA bundle, in addition to the macOS
    Keychain (see wget_macos_ca.c); when the command line asks for HTTPS,
    this trust (and a due CA list refresh) is loaded before any connection
    is opened instead of during the first TLS connection
  * the HSTS preload list defaults to Contents/Resources/hsts/hsts.dafsa
  * --dane uses the DNSSEC root anchors in Contents/Resources/dnssec
  * --verify-sig uses the GnuPG shipped in Contents/Resources/gnupg unless
    WGET_GNUPG=system
"""

import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


def apply(src):
    for name, dests in (("wget_macos_bundle.h", ("libwget", "src")), ("wget_macos_ca.c", ("libwget",))):
        for d in dests:
            shutil.copyfile(os.path.join(HERE, "wget2-macos", name), os.path.join(src, d, name))
            print("  [ok]   copied %s to %s/" % (name, d))

    ssl_c = os.path.join(src, "libwget", "ssl_gnutls.c")
    wget_c = os.path.join(src, "src", "wget.c")
    options_c = os.path.join(src, "src", "options.c")
    gpgme_c = os.path.join(src, "src", "gpgme.c")

    # ---- libwget/ssl_gnutls.c: CA bundle selection + refresh
    patchlib.replace_once(
        ssl_c,
        '#include <wget.h>\n#include "private.h"\n#include "net.h"\n',
        '#include <wget.h>\n#include "private.h"\n#include "net.h"\n'
        "#ifdef __APPLE__\n"
        '#\tinclude "wget_macos_ca.c"\n'
        "#endif\n",
        "ssl_gnutls.c: include wget_macos_ca.c",
    )
    patchlib.replace_once(
        ssl_c,
        '\tif (config.ca_file && !wget_strcmp(config.ca_file, "system"))\n'
        "\t\tconfig.ca_file = wget_ssl_default_ca_bundle_path();\n",
        '\tif (config.ca_file && !wget_strcmp(config.ca_file, "system"))\n'
        "#ifdef __APPLE__\n"
        "\t\tconfig.ca_file = wget_macos_ca_bundle_path(config.check_certificate);\n"
        "#else\n"
        "\t\tconfig.ca_file = wget_ssl_default_ca_bundle_path();\n"
        "#endif\n",
        "ssl_gnutls.c: macOS CA bundle for --ca-certificate=system",
    )

    # ---- src/wget.c: load the TLS trust before downloading starts
    patchlib.replace_once(
        wget_c,
        "\tif (config.background)\n"
        "\t\tfork_to_background();\n"
        "\n",
        "\tif (config.background)\n"
        "\t\tfork_to_background();\n"
        "\n"
        "#ifdef __APPLE__\n"
        "\t// macOS bundle: load the TLS trust (Keychain + Mozilla CA list, which\n"
        "\t// may be refreshed over the network) now, before any connection is\n"
        "\t// open and before the download threads start, if HTTPS will be used.\n"
        "\t// Otherwise this happens on the first TLS connection, as upstream.\n"
        "\tif (config.check_certificate == CHECK_CERTIFICATE_ENABLED) {\n"
        "\t\tint https = config.https_only || config.https_enforce != HTTPS_ENFORCE_NONE;\n"
        "\n"
        "\t\tfor (int it = 1; !https && it < argc; it++)\n"
        "\t\t\thttps = !wget_strncasecmp_ascii(argv[it], \"https://\", 8);\n"
        "\t\tif (https)\n"
        "\t\t\twget_ssl_init();\n"
        "\t}\n"
        "#endif\n"
        "\n",
        "wget.c: load the TLS trust before the first connection",
    )

    # ---- src/wget.c: bundle-relative locale directory
    patchlib.replace_once(
        wget_c,
        '#include "wget_utils.h"\n',
        '#include "wget_utils.h"\n#include "wget_macos_bundle.h"\n',
        "wget.c: include wget_macos_bundle.h",
    )
    patchlib.replace_once(
        wget_c,
        "\tbindtextdomain(PACKAGE, LOCALEDIR);\n\ttextdomain(PACKAGE);\n",
        "#ifdef __APPLE__\n"
        "\t{\n"
        '\t\tchar *macos_localedir = wget_macos_resource_path("locale");\n'
        "\t\tbindtextdomain(PACKAGE, macos_localedir ? macos_localedir : LOCALEDIR);\n"
        "\t\tfree(macos_localedir);\n"
        "\t}\n"
        "#else\n"
        "\tbindtextdomain(PACKAGE, LOCALEDIR);\n"
        "#endif\n"
        "\ttextdomain(PACKAGE);\n",
        "wget.c: translations from Contents/Resources/locale",
    )

    # ---- src/options.c: HSTS preload file and DANE trust anchors
    patchlib.replace_once(
        options_c,
        '#include "wget_testing.h"\n#include "wget_utils.h"\n',
        '#include "wget_testing.h"\n#include "wget_utils.h"\n#include "wget_macos_bundle.h"\n',
        "options.c: include wget_macos_bundle.h",
    )
    patchlib.replace_once(
        options_c,
        "#ifdef WITH_LIBHSTS\n"
        "\tif (config.hsts_preload && !config.hsts_preload_file && *hsts_dist_filename())\n",
        "#if defined WITH_LIBHSTS && defined __APPLE__\n"
        "\tif (config.hsts_preload && !config.hsts_preload_file) {\n"
        '\t\tchar *macos_hsts = wget_macos_resource_path("hsts/hsts.dafsa");\n'
        "\t\tif (macos_hsts) {\n"
        "\t\t\tconfig.hsts_preload_file = wget_strdup(macos_hsts);\n"
        "\t\t\tfree(macos_hsts);\n"
        "\t\t}\n"
        "\t}\n"
        "#endif\n"
        "#ifdef WITH_LIBHSTS\n"
        "\tif (config.hsts_preload && !config.hsts_preload_file && *hsts_dist_filename())\n",
        "options.c: HSTS preload list from Contents/Resources/hsts",
    )
    patchlib.replace_once(
        options_c,
        "\twget_ssl_set_config_int(WGET_SSL_DANE, config.dane);\n",
        "\twget_ssl_set_config_int(WGET_SSL_DANE, config.dane);\n"
        "#ifdef __APPLE__\n"
        '\tif (config.dane && !getenv("GNUTLS_DANE_ROOT_KEY_FILE")) {\n'
        '\t\tchar *macos_ta = wget_macos_resource_path("dnssec/root-anchors.txt");\n'
        "\t\tif (macos_ta) {\n"
        '\t\t\tsetenv("GNUTLS_DANE_ROOT_KEY_FILE", macos_ta, 1);\n'
        "\t\t\tfree(macos_ta);\n"
        "\t\t}\n"
        "\t}\n"
        "#endif\n",
        "options.c: DNSSEC trust anchors for --dane",
    )

    # ---- src/gpgme.c: bundled GnuPG
    patchlib.replace_once(
        gpgme_c,
        "#ifdef WITH_GPGME\n\n#include <gpgme.h>\n",
        "#ifdef WITH_GPGME\n\n#include <gpgme.h>\n"
        "\n"
        "#ifdef __APPLE__\n"
        '#include "wget_macos_bundle.h"\n'
        "\n"
        "/* Use the GnuPG shipped in wget.app/Contents/Resources/gnupg so that\n"
        " * --verify-sig works on a stock macOS.  WGET_GNUPG=system selects the\n"
        " * GnuPG found in PATH instead.  Putting the bundled bin/ first in PATH\n"
        " * makes GPGME's gpgconf lookup (and everything derived from it) agree\n"
        " * with the explicitly set engines. */\n"
        "static char *macos_gnupg_prepare(void)\n"
        "{\n"
        '\tconst char *mode = getenv("WGET_GNUPG"), *path;\n'
        "\tchar *bindir, *gpgconf, *gpg, *newpath;\n"
        "\tint ok;\n"
        "\n"
        '\tif (mode && !wget_strcmp(mode, "system"))\n'
        "\t\treturn NULL;\n"
        '\tif (!(bindir = wget_macos_resource_path("gnupg/bin")))\n'
        "\t\treturn NULL;\n"
        '\tgpgconf = wget_aprintf("%s/gpgconf", bindir);\n'
        '\tgpg = wget_aprintf("%s/gpg", bindir);\n'
        "\tok = gpgconf && gpg && access(gpgconf, X_OK) == 0 && access(gpg, X_OK) == 0;\n"
        "\txfree(gpgconf);\n"
        "\txfree(gpg);\n"
        "\tif (!ok) {\n"
        "\t\tfree(bindir);\n"
        "\t\treturn NULL;\n"
        "\t}\n"
        '\tpath = getenv("PATH");\n'
        '\tnewpath = (path && *path) ? wget_aprintf("%s:%s", bindir, path) : wget_strdup(bindir);\n'
        "\tif (newpath) {\n"
        '\t\tsetenv("PATH", newpath, 1);\n'
        "\t\txfree(newpath);\n"
        "\t}\n"
        "\treturn bindir;\n"
        "}\n"
        "\n"
        "static void macos_gnupg_set_engines(char *bindir)\n"
        "{\n"
        "\tchar *gpgconf, *gpg;\n"
        "\tgpgme_error_t e;\n"
        "\n"
        "\tif (!bindir)\n"
        "\t\treturn;\n"
        '\tgpgconf = wget_aprintf("%s/gpgconf", bindir);\n'
        '\tgpg = wget_aprintf("%s/gpg", bindir);\n'
        "\tif (gpgconf && gpg) {\n"
        "\t\tif ((e = gpgme_set_engine_info(GPGME_PROTOCOL_GPGCONF, gpgconf, NULL)) != GPG_ERR_NO_ERROR)\n"
        '\t\t\tdebug_printf("gpgme_set_engine_info(gpgconf): %s\\n", gpgme_strerror(e));\n'
        "\t\tif ((e = gpgme_set_engine_info(GPGME_PROTOCOL_OpenPGP, gpg, NULL)) != GPG_ERR_NO_ERROR)\n"
        '\t\t\tdebug_printf("gpgme_set_engine_info(gpg): %s\\n", gpgme_strerror(e));\n'
        '\t\tdebug_printf("Using the GnuPG bundled in %s\\n", bindir);\n'
        "\t}\n"
        "\txfree(gpgconf);\n"
        "\txfree(gpg);\n"
        "\tfree(bindir);\n"
        "}\n"
        "#endif /* __APPLE__ */\n",
        "gpgme.c: bundled GnuPG helpers",
    )
    patchlib.replace_once(
        gpgme_c,
        "void init_gpgme(void) {\n"
        "#ifdef WITH_GPGME\n"
        '\tsetlocale (LC_ALL, "");\n'
        "\tgpgme_check_version (NULL);\n",
        "void init_gpgme(void) {\n"
        "#ifdef WITH_GPGME\n"
        '\tsetlocale (LC_ALL, "");\n'
        "#ifdef __APPLE__\n"
        "\tchar *macos_gnupg_bin = macos_gnupg_prepare();\n"
        "#endif\n"
        "\tgpgme_check_version (NULL);\n"
        "#ifdef __APPLE__\n"
        "\tmacos_gnupg_set_engines(macos_gnupg_bin);\n"
        "#endif\n",
        "gpgme.c: use bundled GnuPG in init_gpgme()",
    )


if __name__ == "__main__":
    patchlib.main(apply)
