#!/usr/bin/env python3
"""Convert a Windows .ico into a macOS .iconset directory.

Written against the stdlib only -- no Pillow, no Homebrew.  macOS ships
iconutil to turn the resulting directory into an .icns, but nothing that
reads .ico reliably, so the decoding is done here.

Handles both storage forms found in .ico files: uncompressed DIBs (1/4/8/24/32
bpp, bottom-up, with the separate AND transparency mask) and PNG-compressed
entries, which is how anything 256x256 or larger is normally stored -- and
those are the entries worth having on macOS.

Enlarging uses nearest-neighbour so small pixel-art icons keep their grid
instead of turning to mush; shrinking uses an alpha-weighted box average,
because nearest-neighbour aliases a detailed 256x256 icon badly.  Non-square
icons (Wine's logo.ico is 194x313) are centred on a transparent square.

usage: ico2iconset.py <input.ico> <output.iconset-dir>
"""
import os
import struct
import sys
import zlib

TARGETS = [
    ("icon_16x16.png",        16), ("icon_16x16@2x.png",     32),
    ("icon_32x32.png",        32), ("icon_32x32@2x.png",     64),
    ("icon_128x128.png",     128), ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256), ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512), ("icon_512x512@2x.png", 1024),
]


def die(msg):
    sys.stderr.write("ico2iconset: %s\n" % msg)
    sys.exit(1)


def read_png_size(blob):
    if len(blob) < 24 or not blob.startswith(b"\x89PNG"):
        return None
    w, h = struct.unpack(">II", blob[16:24])
    return w, h


def decode_png(blob):
    """Minimal PNG -> RGBA decoder (8-bit, non-interlaced).

    Icons at 256x256 and above are almost always stored PNG-compressed inside
    the .ico rather than as a DIB, and those are exactly the entries worth
    having on macOS -- so skipping them would throw away the best artwork in
    the file.
    """
    if not blob.startswith(b"\x89PNG"):
        return None
    pos, idat, plte, trns = 8, b"", None, None
    w = h = depth = ctype = interlace = None
    while pos + 8 <= len(blob):
        ln = struct.unpack(">I", blob[pos:pos + 4])[0]
        tag = blob[pos + 4:pos + 8]
        data = blob[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", data)
        elif tag == b"PLTE":
            plte = data
        elif tag == b"tRNS":
            trns = data
        elif tag == b"IDAT":
            idat += data
        elif tag == b"IEND":
            break
        pos += 12 + ln
    if w is None or depth != 8 or interlace != 0:
        return None                    # 16-bit and Adam7 are not worth the code

    nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype)
    if nch is None or (ctype == 3 and plte is None):
        return None
    try:
        raw = zlib.decompress(idat)
    except zlib.error:
        return None

    stride = w * nch
    if len(raw) < (stride + 1) * h:
        return None

    prev = bytearray(stride)
    rows = []
    off = 0
    for _ in range(h):
        f = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        off += 1 + stride
        if f == 1:                                     # Sub
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 0xFF
        elif f == 2:                                   # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:                                   # Average
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:                                   # Paeth
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif f != 0:
            return None
        rows.append(bytes(line))
        prev = line

    px = bytearray(w * h * 4)
    for y, line in enumerate(rows):
        for x in range(w):
            i = x * nch
            if ctype == 6:
                r, g, b, a = line[i], line[i + 1], line[i + 2], line[i + 3]
            elif ctype == 2:
                r, g, b, a = line[i], line[i + 1], line[i + 2], 255
            elif ctype == 0:
                r = g = b = line[i]; a = 255
            elif ctype == 4:
                r = g = b = line[i]; a = line[i + 1]
            else:                                      # palette
                idx = line[i]
                r, g, b = plte[idx * 3:idx * 3 + 3]
                a = trns[idx] if trns and idx < len(trns) else 255
            o = (y * w + x) * 4
            px[o:o + 4] = bytes((r, g, b, a))
    return w, h, bytes(px)


def decode_dib(blob, w, h):
    """Decode an icon DIB (BITMAPINFOHEADER + XOR bitmap + AND mask) to RGBA."""
    if len(blob) < 40:
        return None
    hdr = struct.unpack("<IiiHHIIiiII", blob[:40])
    bw, bh, bpp, comp = hdr[1], hdr[2], hdr[4], hdr[5]
    if comp != 0:                      # BI_RGB only
        return None
    bh //= 2                           # height covers XOR + AND masks
    if bw != w or bh != h:
        w, h = bw, bh
    off = 40
    palette = []
    if bpp <= 8:
        n = 1 << bpp
        for i in range(n):
            b, g, r, _ = blob[off + i * 4: off + i * 4 + 4]
            palette.append((r, g, b))
        off += n * 4

    row_bytes = ((w * bpp + 31) // 32) * 4
    xor = blob[off: off + row_bytes * h]
    off += row_bytes * h
    mask_row = ((w + 31) // 32) * 4
    andmask = blob[off: off + mask_row * h]

    px = bytearray(w * h * 4)
    any_alpha = False
    for y in range(h):
        sy = h - 1 - y                 # DIBs are bottom-up
        for x in range(w):
            if bpp == 32:
                i = sy * row_bytes + x * 4
                b, g, r, a = xor[i], xor[i + 1], xor[i + 2], xor[i + 3]
                if a:
                    any_alpha = True
            elif bpp == 24:
                i = sy * row_bytes + x * 3
                b, g, r = xor[i], xor[i + 1], xor[i + 2]
                a = 255
            elif bpp == 8:
                r, g, b = palette[xor[sy * row_bytes + x]]
                a = 255
            elif bpp in (1, 4):
                per = 8 // bpp
                byte = xor[sy * row_bytes + x // per]
                shift = (per - 1 - (x % per)) * bpp
                r, g, b = palette[(byte >> shift) & ((1 << bpp) - 1)]
                a = 255
            else:
                return None
            o = (y * w + x) * 4
            px[o:o + 4] = bytes((r, g, b, a))

    # A 32bpp icon whose alpha channel is entirely zero is relying on the AND
    # mask instead -- common in icons of this vintage.  Same for <=8bpp, which
    # has no alpha channel at all.
    if andmask and (bpp != 32 or not any_alpha):
        for y in range(h):
            sy = h - 1 - y
            for x in range(w):
                bit = (andmask[sy * mask_row + x // 8] >> (7 - (x % 8))) & 1
                px[(y * w + x) * 4 + 3] = 0 if bit else 255
    return w, h, bytes(px)


def to_square(w, h, rgba):
    """Centre a non-square image on a transparent square canvas."""
    n = max(w, h)
    ox, oy = (n - w) // 2, (n - h) // 2
    out = bytearray(n * n * 4)
    for y in range(h):
        src = y * w * 4
        dst = ((y + oy) * n + ox) * 4
        out[dst:dst + w * 4] = rgba[src:src + w * 4]
    return n, n, bytes(out)


def load_ico(path):
    d = open(path, "rb").read()
    if len(d) < 6:
        die("%s is too small to be an .ico" % path)
    _, typ, n = struct.unpack("<HHH", d[:6])
    if typ != 1 or n == 0:
        die("%s is not an icon file (type=%d entries=%d)" % (path, typ, n))
    images = {}
    for i in range(n):
        w, h, _, _, _, bpp, size, off = struct.unpack(
            "<BBBBHHII", d[6 + i * 16: 22 + i * 16])
        w = w or 256
        h = h or 256
        blob = d[off:off + size]
        got = decode_png(blob) if blob.startswith(b"\x89PNG") else decode_dib(blob, w, h)
        if not got:
            continue
        iw, ih, rgba = got
        if iw != ih:
            # macOS icons must be square, but plenty of Windows icons are not
            # (Wine's own logo.ico is 194x313).  Letterbox onto a transparent
            # square rather than discarding the image or distorting it.
            iw, ih, rgba = to_square(iw, ih, rgba)
        # An .ico usually stores the same image at several depths.  Keep the
        # deepest: 32bpp and PNG entries carry a real alpha channel, 8bpp and
        # 4bpp ones only a 1-bit mask.
        depth = 32 if blob.startswith(b"\x89PNG") else bpp
        prev = images.get(iw)
        if prev is None or depth > prev[0]:
            images[iw] = (depth, rgba)
    if not images:
        die("no usable images found in %s" % path)
    return {s: v[1] for s, v in images.items()}


def write_png(path, size, rgba):
    raw = bytearray()
    for y in range(size):
        raw.append(0)                  # filter: none
        raw += rgba[y * size * 4:(y + 1) * size * 4]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


def scale(rgba, src, dst):
    """Nearest-neighbour when enlarging, box average when shrinking.

    Enlarging pixel art with interpolation smears it; shrinking a detailed
    256x256 icon with nearest-neighbour aliases it badly.  Each direction wants
    the opposite treatment.
    """
    if src == dst:
        return rgba
    out = bytearray(dst * dst * 4)
    if dst > src:
        for y in range(dst):
            base = (y * src // dst) * src * 4
            for x in range(dst):
                o = (y * dst + x) * 4
                i = base + (x * src // dst) * 4
                out[o:o + 4] = rgba[i:i + 4]
        return bytes(out)

    # Shrinking: average each source block, weighting colour by alpha so that
    # transparent pixels do not drag the edges toward black.
    for y in range(dst):
        y0, y1 = y * src // dst, max(y * src // dst + 1, (y + 1) * src // dst)
        for x in range(dst):
            x0, x1 = x * src // dst, max(x * src // dst + 1, (x + 1) * src // dst)
            r = g = b = a = n = 0
            for sy in range(y0, y1):
                row = sy * src * 4
                for sx in range(x0, x1):
                    i = row + sx * 4
                    pa = rgba[i + 3]
                    r += rgba[i] * pa
                    g += rgba[i + 1] * pa
                    b += rgba[i + 2] * pa
                    a += pa
                    n += 1
            o = (y * dst + x) * 4
            if a:
                out[o:o + 4] = bytes((r // a, g // a, b // a, a // n))
            else:
                out[o:o + 4] = b"\x00\x00\x00\x00"
    return bytes(out)


def pick_source(sizes, target):
    """Exact match, else the smallest source larger than the target (shrinking
    keeps detail), else the largest source that divides the target evenly so
    that enlarging stays on the pixel grid."""
    if target in sizes:
        return target
    bigger = [s for s in sizes if s > target]
    if bigger:
        exact = [s for s in bigger if s % target == 0]
        return min(exact) if exact else min(bigger)
    divisors = [s for s in sizes if target % s == 0]
    return max(divisors) if divisors else max(sizes)


def main():
    if len(sys.argv) != 3:
        die("usage: ico2iconset.py <input.ico> <output.iconset-dir>")
    src, out = sys.argv[1], sys.argv[2]
    images = load_ico(src)

    decoded = images

    os.makedirs(out, exist_ok=True)
    sizes = sorted(decoded)
    for name, target in TARGETS:
        s = pick_source(sizes, target)
        write_png(os.path.join(out, name), target, scale(decoded[s], s, target))

    sys.stderr.write("ico2iconset: %s -> %s (sources: %s)\n"
                     % (os.path.basename(src), os.path.basename(out),
                        ", ".join("%dx%d" % (s, s) for s in sizes)))


if __name__ == "__main__":
    main()
