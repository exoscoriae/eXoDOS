#!/usr/bin/env python3
"""Fix embedded-image loading on macOS in GOffice.

go_image_new_from_data() identifies untyped image buffers via GLib's
g_content_type_guess(). GLib's macOS content-type backend determines types
almost exclusively from filename extensions, so a raw in-memory buffer (for
example a PNG embedded in an .ods file) is never recognized and GOffice
gives up with "unrecognized image format".

This inserts a fallback: if GLib could not identify the buffer, let
gdk-pixbuf's magic-byte sniffing have a try (requires gdk-pixbuf built with
gio_sniffing disabled, which this build system does).

Usage: goffice-image-sniff.py <path/to/goffice/utils/go-image.c>
Idempotent; fails loudly if the expected anchor is missing.
"""
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

MARK = "portable-bundle image-sniff patch"
if MARK in src:
    print("goffice-image-sniff: already patched")
    sys.exit(0)

anchor = (
    '\tif (type == NULL) {\n'
    '\t\tg_warning ("unrecognized image format");\n'
    '\t\treturn NULL;\n'
    '\t}\n'
)
if anchor not in src:
    sys.exit("goffice-image-sniff: anchor not found - go-image.c layout changed")

inject = (
    '\t/* Added by portable-bundle image-sniff patch: on macOS, GLib cannot\n'
    '\t * identify raw data buffers, so fall back to gdk-pixbuf sniffing. */\n'
    '\tif (type == NULL && data != NULL && length > 0) {\n'
    '\t\tGdkPixbufLoader *sniff_loader = gdk_pixbuf_loader_new ();\n'
    '\t\tGdkPixbufFormat *sniff_fmt;\n'
    '\t\tgdk_pixbuf_loader_write (sniff_loader, data, length, NULL);\n'
    '\t\tgdk_pixbuf_loader_close (sniff_loader, NULL);\n'
    '\t\tsniff_fmt = gdk_pixbuf_loader_get_format (sniff_loader);\n'
    '\t\tif (sniff_fmt != NULL)\n'
    '\t\t\treal_type = gdk_pixbuf_format_get_name (sniff_fmt);\n'
    '\t\tg_object_unref (sniff_loader);\n'
    '\t\ttype = real_type;\n'
    '\t}\n'
) + anchor

src = src.replace(anchor, inject, 1)
open(path, "w", encoding="utf-8").write(src)
print("goffice-image-sniff: patched", path)
