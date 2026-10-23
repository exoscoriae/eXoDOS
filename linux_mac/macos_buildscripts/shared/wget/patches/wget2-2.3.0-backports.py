#!/usr/bin/env python3
"""Backport upstream wget2 fixes committed after the 2.3.0 release.

All of these are on wget2's master branch (github.com/rockdaboot/wget2):

  08d1af3  Fix a fallback to plaintext via CONNECT proxy  (security: an HTTPS
           request through a CONNECT proxy was sent in cleartext when the TLS
           handshake failed; affects 2.1.0 .. 2.3.0)
  8d7b977  src/wget.c (http_send_request): Fix double free
  acf7f4e  Fix -P/--directory-prefix for absolute paths (2.3.0 regression:
           an absolute -P was appended to the current directory)
  f4a1a28  Load translations from the wget2 text domain (2.3.0 binds "wget"
           but installs wget2.mo, so translations never load)
  f46a29c  Don't report expired HSTS entries as parse failures

The build-system part of the GNULIB_LIBS fix (e80d42a/213b7af) cannot be
backported without re-running autotools; build.sh passes the libraries via
LIBS instead (see recipe_wget2).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402


def apply(src):
    http_c = os.path.join(src, "libwget", "http.c")
    wget_c = os.path.join(src, "src", "wget.c")
    options_c = os.path.join(src, "src", "options.c")
    hsts_c = os.path.join(src, "libwget", "hsts.c")

    # 08d1af3 -- only the libwget/http.c part (the rest is test-suite only)
    patchlib.replace_once(
        http_c,
        "\t\tif (iri->scheme == WGET_IRI_SCHEME_HTTPS) {\n"
        "\t\t\twget_tcp_set_ssl(conn->tcp, 1); // switch SSL on\n"
        "\t\t\twget_tcp_set_ssl_hostname(conn->tcp, iri->host); // enable host name checking\n"
        "\t\t\twget_tcp_tls_start(conn->tcp);\n"
        "\t\t}\n",
        "\t\tif (iri->scheme == WGET_IRI_SCHEME_HTTPS) {\n"
        "\t\t\twget_tcp_set_ssl(conn->tcp, 1); // switch SSL on\n"
        "\t\t\twget_tcp_set_ssl_hostname(conn->tcp, iri->host); // enable host name checking\n"
        "\n"
        "\t\t\tif ((rc = wget_tcp_tls_start(conn->tcp)) != WGET_E_SUCCESS) {\n"
        "\t\t\t\tif (server_stats_callback && rc == WGET_E_CERTIFICATE)\n"
        "\t\t\t\t\tserver_stats_callback(conn, NULL);\n"
        "\t\t\t\twget_http_close(_conn);\n"
        "\t\t\t\treturn rc;\n"
        "\t\t\t}\n"
        "\t\t}\n",
        "08d1af3 CONNECT proxy: abort on TLS failure instead of sending plaintext",
    )
    patchlib.require(http_c, "server_stats_callback", "08d1af3 precondition")

    # 8d7b977
    patchlib.replace_once(
        wget_c,
        "\tif ((rc = wget_http_send_request(conn, &req)) != WGET_E_SUCCESS) {\n"
        "\t\twget_buffer_free(&context->body);\n"
        "\t\txfree(context);\n"
        "\t\twget_http_free_request(&req);\n"
        "\t}\n",
        "\tif ((rc = wget_http_send_request(conn, &req)) != WGET_E_SUCCESS) {\n"
        "\t\t// context has already been freed by free_user_data\n"
        "\t\twget_http_free_request(&req);\n"
        "\t}\n",
        "8d7b977 http_send_request double free",
    )

    # acf7f4e
    patchlib.replace_once(
        options_c,
        "\tif (config.directory_prefix) {\n"
        "\t\tchar *cwd = getcwd(NULL, 0);\n"
        "\t\tif (!cwd) {\n"
        "\t\t\terror_printf_exit(_(\"Failed to get current directory\\n\"));\n"
        "\t\t}\n"
        "\t\tchar *unresolved_path = wget_aprintf(\"%s/%s\", cwd, config.directory_prefix);\n"
        "\t\txfree(cwd);\n"
        "\t\tchar *resolved_path = wget_path_sanitize(unresolved_path);\n"
        "\t\txfree(unresolved_path);\n",
        "\tif (config.directory_prefix) {\n"
        "\t\tchar *resolved_path = NULL;\n"
        "\n"
        "\t\t// If directory_prefix is an absolute path, don't prepend cwd\n"
        "\t\tif (config.directory_prefix[0] == '/') {\n"
        "\t\t\tresolved_path = wget_path_sanitize(config.directory_prefix);\n"
        "\t\t} else {\n"
        "\t\t\tchar *cwd = getcwd(NULL, 0);\n"
        "\t\t\tif (!cwd) {\n"
        "\t\t\t\terror_printf_exit(_(\"Failed to get current directory\\n\"));\n"
        "\t\t\t}\n"
        "\t\t\tchar *unresolved_path = wget_aprintf(\"%s/%s\", cwd, config.directory_prefix);\n"
        "\t\t\txfree(cwd);\n"
        "\t\t\tresolved_path = wget_path_sanitize(unresolved_path);\n"
        "\t\t\txfree(unresolved_path);\n"
        "\t\t}\n"
        "\n",
        "acf7f4e absolute --directory-prefix",
    )

    # f4a1a28 (the macOS bundle patch later swaps LOCALEDIR for the
    # bundle-relative locale directory)
    patchlib.replace_once(
        wget_c,
        "\tbindtextdomain(\"wget\", LOCALEDIR);\n\ttextdomain(\"wget\");\n",
        "\tbindtextdomain(PACKAGE, LOCALEDIR);\n\ttextdomain(PACKAGE);\n",
        "f4a1a28 use the wget2 text domain",
    )

    # f46a29c
    patchlib.replace_once(
        hsts_c,
        "\t\t\tif (hsts.expires < now) {\n"
        "\t\t\t\t// drop expired entry, hsts_db_add_entry() removes entries with maxage=0;\n"
        "\t\t\t\thsts.maxage = 0;\n"
        "\t\t\t\tgoto next;\n"
        "\t\t\t}\n",
        "\t\t\tif (hsts.expires < now) {\n"
        "\t\t\t\t// drop expired entry silently, it is not a parse error\n"
        "\t\t\t\tdeinit_hsts(&hsts);\n"
        "\t\t\t\tcontinue;\n"
        "\t\t\t}\n",
        "f46a29c expired HSTS entries are not parse errors",
    )


if __name__ == "__main__":
    patchlib.main(apply)
