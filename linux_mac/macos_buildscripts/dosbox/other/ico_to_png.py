#!/usr/bin/env python3
"""
ico_to_png.py — Extract the largest image from a Windows .ico file and save
it as a PNG. Pure Python standard library; no Pillow, no external tools.

Used by package_macos.sh to turn the DOSBox ECE icon (src/dosbox.ico inside
the ECE source tree — the same icon Yesterplay's Windows builds embed in
dosbox.exe) into the source image for the .app's .icns.

Supports:
  * PNG-compressed entries (Vista+ style, typically the 256px image)
  * Uncompressed BMP/DIB entries at 32, 24, 8, 4 and 1 bits per pixel
    (with the 1-bit AND transparency mask applied)

Usage:
    python3 ico_to_png.py input.ico output.png
Exit code 0 on success, non-zero on any failure (caller falls back).
"""

import struct
import sys
import zlib

PNG_MAGIC = b'\x89PNG\r\n\x1a\n'


def write_png(path, width, height, rgba_rows):
    """Write an RGBA PNG using only zlib + struct."""
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        c += struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff)
        return c

    raw = b''.join(b'\x00' + row for row in rgba_rows)   # filter 0 per row
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(PNG_MAGIC)
        f.write(chunk(b'IHDR', ihdr))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def png_dimensions(data):
    """Width/height from a PNG blob's IHDR."""
    if len(data) < 24 or not data.startswith(PNG_MAGIC):
        return None
    w, h = struct.unpack('>II', data[16:24])
    return w, h


def decode_dib(data):
    """Decode an ICO BMP/DIB entry into (width, height, rgba_rows)."""
    if len(data) < 40:
        raise ValueError("DIB header too short")
    (bi_size, bi_width, bi_height, bi_planes, bi_bitcount,
     bi_compression) = struct.unpack('<IiiHHI', data[:20])
    if bi_size < 40:
        raise ValueError(f"unsupported DIB header size {bi_size}")
    if bi_compression != 0:
        raise ValueError(f"unsupported DIB compression {bi_compression}")

    width = bi_width
    height = bi_height // 2          # XOR + AND stacked
    if width <= 0 or height <= 0:
        raise ValueError("bad DIB dimensions")

    off = bi_size
    palette = []
    if bi_bitcount <= 8:
        ncolors = struct.unpack('<I', data[32:36])[0] or (1 << bi_bitcount)
        for i in range(ncolors):
            b, g, r, _ = struct.unpack_from('<BBBB', data, off + i * 4)
            palette.append((r, g, b))
        off += ncolors * 4

    def row_size(bits):
        return ((width * bits + 31) // 32) * 4

    xor_stride = row_size(bi_bitcount)
    and_stride = row_size(1)
    xor_start = off
    and_start = off + xor_stride * height

    have_and_mask = (and_start + and_stride * height) <= len(data)

    rows = []
    any_alpha = False
    for y in range(height):                       # top-down output
        src_y = height - 1 - y                    # DIB rows are bottom-up
        xrow = xor_start + src_y * xor_stride
        arow = and_start + src_y * and_stride
        out = bytearray()
        for x in range(width):
            if bi_bitcount == 32:
                b, g, r, a = struct.unpack_from('<BBBB', data, xrow + x * 4)
            elif bi_bitcount == 24:
                b, g, r = struct.unpack_from('<BBB', data, xrow + x * 3)
                a = 255
            elif bi_bitcount == 8:
                idx = data[xrow + x]
                r, g, b = palette[idx]
                a = 255
            elif bi_bitcount == 4:
                byte = data[xrow + x // 2]
                idx = (byte >> 4) if x % 2 == 0 else (byte & 0x0F)
                r, g, b = palette[idx]
                a = 255
            elif bi_bitcount == 1:
                byte = data[xrow + x // 8]
                idx = (byte >> (7 - x % 8)) & 1
                r, g, b = palette[idx]
                a = 255
            else:
                raise ValueError(f"unsupported bit depth {bi_bitcount}")

            if have_and_mask and bi_bitcount != 32:
                mbyte = data[arow + x // 8]
                if (mbyte >> (7 - x % 8)) & 1:
                    a = 0
            if a not in (0, 255):
                any_alpha = True
            out += bytes((r, g, b, a))
        rows.append(bytes(out))

    # Some 32bpp icons leave the alpha channel all-zero and rely purely on
    # the AND mask. Detect that and fall back to the mask.
    if bi_bitcount == 32 and not any_alpha:
        all_zero = all(row[i] == 0 for row in rows for i in range(3, len(row), 4))
        if all_zero and have_and_mask:
            fixed = []
            for y, row in enumerate(rows):
                src_y = height - 1 - y
                arow = and_start + src_y * and_stride
                out = bytearray(row)
                for x in range(width):
                    mbyte = data[arow + x // 8]
                    out[x * 4 + 3] = 0 if ((mbyte >> (7 - x % 8)) & 1) else 255
                fixed.append(bytes(out))
            rows = fixed

    return width, height, rows


def main():
    if len(sys.argv) != 3:
        print("usage: ico_to_png.py input.ico output.png", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    with open(src, 'rb') as f:
        data = f.read()

    if len(data) < 6:
        print("ERROR: not an ICO file (too short)", file=sys.stderr)
        return 1
    reserved, ico_type, count = struct.unpack('<HHH', data[:6])
    if reserved != 0 or ico_type not in (1, 2) or count == 0:
        print("ERROR: not a valid ICO file", file=sys.stderr)
        return 1

    entries = []
    for i in range(count):
        off = 6 + i * 16
        if off + 16 > len(data):
            break
        (w, h, _colors, _rsvd, _planes, bitcount,
         size, img_off) = struct.unpack_from('<BBBBHHII', data, off)
        w = w or 256
        h = h or 256
        if img_off + size > len(data):
            continue
        blob = data[img_off:img_off + size]
        is_png = blob.startswith(PNG_MAGIC)
        if is_png:
            dims = png_dimensions(blob)
            if dims:
                w, h = dims
        entries.append({
            'w': w, 'h': h, 'bits': bitcount or 32,
            'png': is_png, 'blob': blob,
        })

    if not entries:
        print("ERROR: no readable images in ICO", file=sys.stderr)
        return 1

    # Largest area first; on ties prefer PNG, then higher bit depth.
    entries.sort(key=lambda e: (e['w'] * e['h'], e['png'], e['bits']),
                 reverse=True)

    last_err = None
    for e in entries:
        try:
            if e['png']:
                with open(dst, 'wb') as f:
                    f.write(e['blob'])
            else:
                w, h, rows = decode_dib(e['blob'])
                write_png(dst, w, h, rows)
            print(f"extracted {e['w']}x{e['h']} "
                  f"({'png' if e['png'] else str(e['bits']) + 'bpp dib'}) "
                  f"-> {dst}")
            return 0
        except Exception as exc:            # try the next-best entry
            last_err = exc
            continue

    print(f"ERROR: could not decode any ICO entry: {last_err}", file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
