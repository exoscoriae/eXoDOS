#!/usr/bin/env python3
"""Make GOffice's compiled-in paths overridable via environment variables.

libgoffice hard-codes GOFFICE_DATADIR / ICONDIR / LOCALEDIR / LIBDIR /
EXTERNPLUGINDIR at configure time (goffice/goffice.c) on non-Windows,
non-GtkOSXApplication builds. This inserts env-var overrides at the top of
libgoffice_init() so a launcher can relocate everything into a .app bundle.

Usage: relocate-goffice.py <path/to/goffice/goffice.c>
Idempotent; fails loudly if the expected anchor is missing.
"""
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARK = "portable-bundle relocation patch"
if MARK in src:
    print("relocate-goffice: already patched")
    sys.exit(0)

anchor = "libgoffice_init (void)\n{\n\tif (initialized++)\n\t\treturn;\n"
if anchor not in src:
    sys.exit("relocate-goffice: anchor not found - goffice.c layout changed")

inject = anchor + """
\t/* Added by portable-bundle relocation patch */
\t{
\t\tconst char *e;
\t\tif ((e = g_getenv ("GOFFICE_DATADIR")) && *e)
\t\t\tlibgoffice_data_dir = g_strdup (e);
\t\tif ((e = g_getenv ("GOFFICE_ICONDIR")) && *e)
\t\t\tlibgoffice_icon_dir = g_strdup (e);
\t\tif ((e = g_getenv ("GOFFICE_LOCALEDIR")) && *e)
\t\t\tlibgoffice_locale_dir = g_strdup (e);
\t\tif ((e = g_getenv ("GOFFICE_LIBDIR")) && *e)
\t\t\tlibgoffice_lib_dir = g_strdup (e);
\t\tif ((e = g_getenv ("GOFFICE_EXTERNPLUGINDIR")) && *e)
\t\t\tlibgoffice_extern_plugin_dir = g_strdup (e);
\t}
"""

src = src.replace(anchor, inject, 1)
open(path, "w", encoding="utf-8").write(src)
print("relocate-goffice: patched", path)
