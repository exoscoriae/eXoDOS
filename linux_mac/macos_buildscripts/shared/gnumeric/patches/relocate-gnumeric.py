#!/usr/bin/env python3
"""Make Gnumeric's compiled-in paths overridable via environment variables.

On non-Windows platforms Gnumeric hard-codes GNUMERIC_LIBDIR / DATADIR /
LOCALEDIR / EXTERNPLUGINDIR at configure time (src/gutils.c). For a
relocatable .app bundle the launcher must be able to point these at the
bundle. This script rewrites gutils.c so each path first consults an
environment variable of the same name.

Usage: relocate-gnumeric.py <path/to/src/gutils.c>
Idempotent; fails loudly if the expected anchors are missing.
"""
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARK = "gnm_env_override"
if MARK in src:
    print("relocate-gnumeric: already patched")
    sys.exit(0)

helper = """\
/* Added by portable-bundle relocation patch */
static const char *
gnm_env_override (const char *var, const char *def)
{
\tconst char *e = g_getenv (var);
\treturn (e && *e) ? e : def;
}

"""

anchor = "static gboolean gutils_inited = FALSE;"
if anchor not in src:
    sys.exit("relocate-gnumeric: anchor 1 not found - gutils.c layout changed")
src = src.replace(anchor, helper + anchor, 1)

repl = [
    ("gnumeric_lib_dir = g_strdup (GNUMERIC_LIBDIR);",
     'gnumeric_lib_dir = g_strdup (gnm_env_override ("GNUMERIC_LIBDIR", GNUMERIC_LIBDIR));'),
    ("gnumeric_data_dir = g_strdup (GNUMERIC_DATADIR);",
     'gnumeric_data_dir = g_strdup (gnm_env_override ("GNUMERIC_DATADIR", GNUMERIC_DATADIR));'),
    ("gnumeric_locale_dir = g_strdup (GNUMERIC_LOCALEDIR);",
     'gnumeric_locale_dir = g_strdup (gnm_env_override ("GNUMERIC_LOCALEDIR", GNUMERIC_LOCALEDIR));'),
    ("gnumeric_extern_plugin_dir = g_strdup (GNUMERIC_EXTERNPLUGINDIR);",
     'gnumeric_extern_plugin_dir = g_strdup (gnm_env_override ("GNUMERIC_EXTERNPLUGINDIR", GNUMERIC_EXTERNPLUGINDIR));'),
]
for old, new in repl:
    if old not in src:
        sys.exit("relocate-gnumeric: anchor not found: %r" % old)
    src = src.replace(old, new, 1)

open(path, "w", encoding="utf-8").write(src)
print("relocate-gnumeric: patched", path)
