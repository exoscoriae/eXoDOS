#!/usr/bin/env python3
"""Fix GOffice image decoding with modern gdk-pixbuf (>= 2.44 / glycin).

goffice/utils/go-pixbuf.c fetches the decoded pixbuf from a GdkPixbufLoader
BEFORE calling gdk_pixbuf_loader_close(). With classic in-process loaders the
pixbuf happens to be available right after the final write, so this worked
for two decades. With out-of-process loaders (gdk-pixbuf >= 2.44, glycin, as
shipped in recent GNOME runtimes) the pixbuf only becomes available at
close(), so goffice silently stores NULL: images keep zero size and are never
drawn - no warning, no placeholder.

This rewrites go_pixbuf_create_pixbuf() to close the loader first and fetch
the pixbuf afterwards, which is correct with both loader generations.

Usage: goffice-pixbuf-close.py <path/to/goffice/utils/go-pixbuf.c>
Idempotent; fails loudly if the function cannot be located.
"""
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARK = "portable-bundle pixbuf-close patch"
if MARK in src:
    print("goffice-pixbuf-close: already patched")
    sys.exit(0)

# Match the whole function: from its signature to the first line that is a
# bare closing brace (inner blocks close with an indented brace).
pattern = re.compile(
    r"static void\n"
    r"go_pixbuf_create_pixbuf \(GOPixbuf \*pixbuf, GError \*\*error\)\n"
    r"\{.*?\n\}\n",
    re.DOTALL,
)
m = pattern.search(src)
if not m:
    sys.exit("goffice-pixbuf-close: go_pixbuf_create_pixbuf not found - layout changed")
if "gdk_pixbuf_loader_write" not in m.group(0):
    sys.exit("goffice-pixbuf-close: matched function looks wrong; refusing to patch")

replacement = (
    "static void\n"
    "go_pixbuf_create_pixbuf (GOPixbuf *pixbuf, GError **error)\n"
    "{\n"
    "\t/* portable-bundle pixbuf-close patch: the loader must be CLOSED\n"
    "\t * before the pixbuf is fetched; with out-of-process loaders\n"
    "\t * (gdk-pixbuf >= 2.44 / glycin) gdk_pixbuf_loader_get_pixbuf()\n"
    "\t * returns NULL until gdk_pixbuf_loader_close() is called. */\n"
    "\tGOImage *image = GO_IMAGE (pixbuf);\n"
    "\tGdkPixbufLoader *loader = gdk_pixbuf_loader_new_with_type (pixbuf->type, NULL);\n"
    "\tif (loader) {\n"
    "\t\tgboolean ok = gdk_pixbuf_loader_write (loader, image->data, image->data_length, error);\n"
    "\t\tif (!gdk_pixbuf_loader_close (loader, (ok && error && *error == NULL) ? error : NULL))\n"
    "\t\t\tok = FALSE;\n"
    "\t\tif (ok) {\n"
    "\t\t\tGdkPixbuf *pix = gdk_pixbuf_loader_get_pixbuf (loader);\n"
    "\t\t\tif (pix)\n"
    "\t\t\t\tg_object_set (pixbuf, \"pixbuf\", pix, NULL);\n"
    "\t\t}\n"
    "\t\tg_object_unref (loader);\n"
    "\t}\n"
    "}\n"
)

src = src[:m.start()] + replacement + src[m.end():]
open(path, "w", encoding="utf-8").write(src)
print("goffice-pixbuf-close: patched", path)
