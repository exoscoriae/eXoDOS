#!/usr/bin/env python3
"""Audit Mach-O files for "runs on a stock macOS N" compatibility.

Pure Python (stdlib only), so it does not depend on the output format of
otool/nm/vtool.  For every Mach-O file found under the given paths (fat or
thin; *.dSYM bundles are skipped) and for every architecture slice it checks:

  arch      the file contains exactly the expected architectures
  minos     LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX platform is macOS and the
            minimum OS version is not newer than --min
  fixups    no LC_DYLD_CHAINED_FIXUPS / LC_DYLD_EXPORTS_TRIE (these need a
            newer dyld than macOS 11 offers for x86_64/arm64)
  dylibs    every LC_LOAD_DYLIB-like command points at an allowed system
            library (other OS libraries: warning; anything else: failure);
            no LC_LOAD_WEAK_DYLIB; no @rpath/@loader_path references
  rpath     no LC_RPATH at all (everything is linked statically)
  weak      no weakly imported symbols except the allow-list (a weak import
            of a regular API means "newer than the deployment target")
  symbols   with --sdk: every imported symbol is exported, for that
            architecture, by the library it is bound to in the given SDK's
            .tbd stubs (follows re-exported libraries)
  leaks     with --leak: the given strings (e.g. the build directory) do not
            occur in the file (reported as warnings)
  signature with --require-signature: LC_CODE_SIGNATURE is present

Exit status 0 when nothing FAILed, 1 otherwise.
"""

import argparse
import os
import re
import struct
import sys

# ----------------------------------------------------------------- constants

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
MH_MAGIC = 0xFEEDFACE

CPU_TYPES = {
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    7: "i386",
    12: "arm",
}
CPU_SUBTYPE_ARM64E = 2

LC_REQ_DYLD = 0x80000000
LC_SYMTAB = 0x2
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_CODE_SIGNATURE = 0x1D
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_VERSION_MIN_MACOSX = 0x24
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
LC_DYLD_EXPORTS_TRIE = 0x33 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

DYLIB_CMDS = {
    LC_LOAD_DYLIB: "LC_LOAD_DYLIB",
    LC_LOAD_WEAK_DYLIB: "LC_LOAD_WEAK_DYLIB",
    LC_REEXPORT_DYLIB: "LC_REEXPORT_DYLIB",
    LC_LAZY_LOAD_DYLIB: "LC_LAZY_LOAD_DYLIB",
    LC_LOAD_UPWARD_DYLIB: "LC_LOAD_UPWARD_DYLIB",
}

PLATFORM_MACOS = 1

N_STAB = 0xE0
N_TYPE = 0x0E
N_EXT = 0x01
N_UNDF = 0x0
N_WEAK_REF = 0x0040
SELF_LIBRARY_ORDINAL = 0x0
DYNAMIC_LOOKUP_ORDINAL = 0xFE
EXECUTABLE_ORDINAL = 0xFF

DEFAULT_ALLOWED_DYLIBS = [
    r"^/usr/lib/libSystem\.B\.dylib$",
    r"^/usr/lib/libresolv\.9\.dylib$",
    r"^/System/Library/Frameworks/CoreFoundation\.framework/Versions/A/CoreFoundation$",
    r"^/System/Library/Frameworks/Security\.framework/Versions/A/Security$",
    r"^/System/Library/Frameworks/SystemConfiguration\.framework/Versions/A/SystemConfiguration$",
    r"^/System/Library/Frameworks/CoreServices\.framework/Versions/A/CoreServices$",
]

# Weak imports that are weak by design (declared __weak_import__ in the SDK,
# used by the FD_SET macros since Xcode 11.4) and are guarded by libc itself.
DEFAULT_ALLOWED_WEAK = ["___darwin_check_fd_set_overflow"]


def fmt_version(v):
    s = "%d.%d" % (v >> 16, (v >> 8) & 0xFF)
    if v & 0xFF:
        s += ".%d" % (v & 0xFF)
    return s


def parse_version(s):
    parts = [int(x) for x in s.split(".")] + [0, 0]
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


# ------------------------------------------------------------ Mach-O parsing


class Slice(object):
    def __init__(self, arch):
        self.arch = arch
        self.filetype = None
        self.platform = None
        self.minos = None
        self.sdk = None
        self.dylibs = []          # (cmdname, path)
        self.rpaths = []
        self.has_signature = False
        self.chained_fixups = False
        self.exports_trie = False
        self.undefined = []       # (name, weak, ordinal)
        self.id_dylib = None


def _cstr(buf, off, limit=None):
    end = buf.find(b"\0", off, limit if limit is not None else len(buf))
    if end < 0:
        end = limit if limit is not None else len(buf)
    return buf[off:end].decode("utf-8", "replace")


def parse_thin(data, base, size, arch_hint=None):
    hdr = data[base:base + 32]
    if len(hdr) < 28:
        raise ValueError("truncated Mach-O header")
    magic = struct.unpack_from("<I", hdr, 0)[0]
    if magic == MH_MAGIC:
        raise ValueError("32-bit Mach-O slice")
    if magic != MH_MAGIC_64:
        raise ValueError("not a little-endian 64-bit Mach-O (magic 0x%08x)" % magic)
    _, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", hdr, 0)
    arch = CPU_TYPES.get(cputype & 0xFFFFFFFF, "cpu%#x" % (cputype & 0xFFFFFFFF))
    if arch == "arm64" and (cpusubtype & 0xFF) == CPU_SUBTYPE_ARM64E:
        arch = "arm64e"
    sl = Slice(arch)
    sl.filetype = filetype

    off = base + 32
    end = off + sizeofcmds
    symtab = None
    for _ in range(ncmds):
        if off + 8 > end:
            raise ValueError("load commands overrun")
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8 or off + cmdsize > end:
            raise ValueError("bad load command size")
        if cmd in DYLIB_CMDS:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            sl.dylibs.append((DYLIB_CMDS[cmd], _cstr(data, off + name_off, off + cmdsize)))
        elif cmd == LC_ID_DYLIB:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            sl.id_dylib = _cstr(data, off + name_off, off + cmdsize)
        elif cmd == LC_RPATH:
            p_off = struct.unpack_from("<I", data, off + 8)[0]
            sl.rpaths.append(_cstr(data, off + p_off, off + cmdsize))
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", data, off + 8)
            sl.platform = platform
            sl.minos = minos if sl.minos is None else max(sl.minos, minos)
            sl.sdk = sdk
        elif cmd == LC_VERSION_MIN_MACOSX:
            version, sdk = struct.unpack_from("<II", data, off + 8)
            sl.platform = PLATFORM_MACOS
            sl.minos = version if sl.minos is None else max(sl.minos, version)
            sl.sdk = sdk
        elif cmd == LC_CODE_SIGNATURE:
            sl.has_signature = True
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            sl.chained_fixups = True
        elif cmd == LC_DYLD_EXPORTS_TRIE:
            sl.exports_trie = True
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize

    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        for i in range(nsyms):
            e = base + symoff + i * 16
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, e)
            if n_type & N_STAB:
                continue
            if (n_type & N_TYPE) != N_UNDF or not (n_type & N_EXT):
                continue
            if n_value != 0:
                continue  # common symbol
            name = _cstr(data, base + stroff + n_strx, base + stroff + strsize)
            ordinal = (n_desc >> 8) & 0xFF
            sl.undefined.append((name, bool(n_desc & N_WEAK_REF), ordinal))
    return sl


def parse_macho(path):
    """Return a list of Slice objects, or None if PATH is not a Mach-O file."""
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return None
        be = struct.unpack(">I", head[:4])[0]
        le = struct.unpack("<I", head[:4])[0]
        if be not in (FAT_MAGIC, FAT_MAGIC_64) and le not in (MH_MAGIC_64, MH_MAGIC):
            return None
        f.seek(0)
        data = f.read()

    if be in (FAT_MAGIC, FAT_MAGIC_64):
        nfat = struct.unpack_from(">I", data, 4)[0]
        if nfat == 0 or nfat > 32:
            return None  # e.g. a Java class file (same magic)
        slices = []
        for i in range(nfat):
            if be == FAT_MAGIC:
                cputype, cpusub, offset, size, align = struct.unpack_from(">iiIII", data, 8 + i * 20)
            else:
                cputype, cpusub, offset, size, align, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            slices.append(parse_thin(data, offset, size))
        return slices, data
    return [parse_thin(data, 0, len(data))], data


# ---------------------------------------------------------------- TBD stubs


def _flow_list(text):
    """Parse the inside of a YAML flow sequence: 'a, 'b c', d' -> list."""
    items = []
    for raw in text.split(","):
        v = raw.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        if v:
            items.append(v)
    return items


class TBDIndex(object):
    """Exported symbols per (install-name, arch) taken from an SDK's .tbd files."""

    KEY_RE = re.compile(r"([A-Za-z0-9_-]+):\s*\[([^\]]*)\]", re.S)

    def __init__(self, sdk):
        self.sdk = sdk
        self.docs = {}        # install-name -> list of (archs, symbols)
        self.reexports = {}   # install-name -> list of (archs, [install-names])
        self.parsed_files = set()

    def _tbd_path_for(self, install_name):
        rel = install_name.lstrip("/")
        cands = []
        if rel.endswith(".dylib"):
            cands.append(rel[:-len(".dylib")] + ".tbd")
        else:
            cands.append(rel + ".tbd")
            m = re.match(r"(.*/([^/]+)\.framework)/Versions/[^/]+/\2$", rel)
            if m:
                cands.append(m.group(1) + "/" + m.group(2) + ".tbd")
        for c in cands:
            p = os.path.join(self.sdk, c)
            if os.path.exists(p):
                return p
        return None

    @staticmethod
    def _archs(targets):
        out = set()
        for t in targets:
            a = t.split("-")[0]
            out.add(a)
        return out

    def _parse_file(self, path):
        if path in self.parsed_files:
            return
        self.parsed_files.add(path)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        for doc in re.split(r"^---.*$", text, flags=re.M):
            m = re.search(r"^install-name:\s*'?\"?([^'\"\n]+)", doc, re.M)
            if not m:
                continue
            name = m.group(1).strip()
            # split top-level sections
            sections = re.split(r"^(?=[A-Za-z][A-Za-z0-9_-]*:)", doc, flags=re.M)
            for sec in sections:
                head = sec.split(":", 1)[0].strip()
                if head in ("exports", "reexports"):
                    for item in re.split(r"^\s*-\s+", sec, flags=re.M)[1:]:
                        kv = dict((k, _flow_list(v)) for k, v in self.KEY_RE.findall(item))
                        archs = self._archs(kv.get("targets", kv.get("archs", [])))
                        syms = set()
                        for key in ("symbols", "weak-symbols", "thread-local-symbols", "weak-def-symbols"):
                            syms.update(kv.get(key, []))
                        for cls in kv.get("objc-classes", []):
                            syms.add("_OBJC_CLASS_$_" + cls)
                            syms.add("_OBJC_METACLASS_$_" + cls)
                            syms.add("_OBJC_EHTYPE_$_" + cls)
                        for cls in kv.get("objc-eh-types", []):
                            syms.add("_OBJC_EHTYPE_$_" + cls)
                        for iv in kv.get("objc-ivars", []):
                            syms.add("_OBJC_IVAR_$_" + iv)
                        self.docs.setdefault(name, []).append((archs, syms))
                elif head == "reexported-libraries":
                    for item in re.split(r"^\s*-\s+", sec, flags=re.M)[1:]:
                        kv = dict((k, _flow_list(v)) for k, v in self.KEY_RE.findall(item))
                        archs = self._archs(kv.get("targets", kv.get("archs", [])))
                        self.reexports.setdefault(name, []).append((archs, kv.get("libraries", [])))

    def _load(self, install_name):
        if install_name in self.docs:
            return True
        p = self._tbd_path_for(install_name)
        if p:
            self._parse_file(p)
        return install_name in self.docs

    def exports(self, install_name, arch, _seen=None):
        """All symbols INSTALL_NAME exports for ARCH (re-exports included)."""
        if _seen is None:
            _seen = set()
        if install_name in _seen:
            return set()
        _seen.add(install_name)
        if not self._load(install_name):
            return None
        out = set()
        for archs, syms in self.docs.get(install_name, []):
            if arch in archs:
                out |= syms
        for archs, libs in self.reexports.get(install_name, []):
            if arch in archs:
                for lib in libs:
                    sub = self.exports(lib, arch, _seen)
                    if sub:
                        out |= sub
        return out


# --------------------------------------------------------------------- audit


class Report(object):
    def __init__(self):
        self.fails = 0
        self.warns = 0

    def fail(self, path, msg):
        self.fails += 1
        print("FAIL  %s: %s" % (path, msg))

    def warn(self, path, msg):
        self.warns += 1
        print("WARN  %s: %s" % (path, msg))


def iter_files(paths):
    for p in paths:
        if os.path.isfile(p) and not os.path.islink(p):
            yield p
            continue
        for root, dirs, files in os.walk(p):
            dirs[:] = sorted(d for d in dirs if not d.endswith(".dSYM"))
            for fn in sorted(files):
                fp = os.path.join(root, fn)
                if not os.path.islink(fp):
                    yield fp


def audit(args):
    rep = Report()
    min_v = parse_version(args.min)
    expected_archs = set(a for a in args.archs.split(",") if a)
    allowed = [re.compile(r) for r in (args.allow_dylib or DEFAULT_ALLOWED_DYLIBS)]
    allowed_weak = set(DEFAULT_ALLOWED_WEAK + (args.allow_weak or []))
    tbd = TBDIndex(args.sdk) if args.sdk else None
    export_cache = {}
    count = 0

    for path in iter_files(args.paths):
        try:
            parsed = parse_macho(path)
        except (ValueError, struct.error) as e:
            rep.fail(path, "cannot parse Mach-O: %s" % e)
            continue
        if parsed is None:
            continue
        slices, data = parsed
        count += 1
        rel = os.path.relpath(path, args.relative_to) if args.relative_to else path
        archs = [s.arch for s in slices]

        if expected_archs and sorted(archs) != sorted(expected_archs):
            rep.fail(rel, "architectures %s, expected %s" % (",".join(archs), ",".join(sorted(expected_archs))))

        for sl in slices:
            tag = "%s[%s]" % (rel, sl.arch)
            if sl.platform is None or sl.minos is None:
                rep.fail(tag, "no LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX")
            else:
                if sl.platform != PLATFORM_MACOS:
                    rep.fail(tag, "platform %d is not macOS" % sl.platform)
                if sl.minos > min_v:
                    rep.fail(tag, "minimum macOS %s is newer than %s" % (fmt_version(sl.minos), args.min))
                if args.max_sdk and sl.sdk is not None and sl.sdk > parse_version(args.max_sdk):
                    rep.fail(tag, "linked against SDK %s (expected <= %s)" % (fmt_version(sl.sdk), args.max_sdk))
            if sl.chained_fixups or sl.exports_trie:
                if min_v < parse_version("12.0"):
                    rep.fail(tag, "uses LC_DYLD_CHAINED_FIXUPS/LC_DYLD_EXPORTS_TRIE (needs a newer dyld)")
            for cmd, lib in sl.dylibs:
                if cmd == "LC_LOAD_WEAK_DYLIB":
                    rep.fail(tag, "weakly linked library %s" % lib)
                if lib.startswith("@"):
                    rep.fail(tag, "relative library reference %s" % lib)
                elif any(r.search(lib) for r in allowed):
                    pass
                elif lib.startswith("/usr/lib/") or lib.startswith("/System/Library/"):
                    # part of every macOS (its symbols are still checked
                    # against the SDK), but not expected in this build
                    rep.warn(tag, "links OS library %s (expected the bundled static one?)" % lib)
                else:
                    rep.fail(tag, "links non-system library %s" % lib)
            for rp in sl.rpaths:
                rep.fail(tag, "has LC_RPATH %s" % rp)
            if args.require_signature and not sl.has_signature:
                rep.fail(tag, "no code signature")

            for name, weak, ordinal in sl.undefined:
                if weak and name not in allowed_weak:
                    rep.fail(tag, "weak import %s (API newer than the deployment target?)" % name)
                if ordinal == DYNAMIC_LOOKUP_ORDINAL:
                    rep.fail(tag, "flat/dynamic lookup of %s" % name)
                    continue
                if tbd is None or ordinal in (SELF_LIBRARY_ORDINAL, EXECUTABLE_ORDINAL):
                    continue
                if ordinal > len(sl.dylibs):
                    rep.fail(tag, "symbol %s bound to missing library ordinal %d" % (name, ordinal))
                    continue
                lib = sl.dylibs[ordinal - 1][1]
                key = (lib, sl.arch)
                if key not in export_cache:
                    export_cache[key] = tbd.exports(lib, sl.arch)
                exp = export_cache[key]
                if exp is None:
                    rep.fail(tag, "no SDK stub for %s (cannot verify %s)" % (lib, name))
                elif name not in exp:
                    rep.fail(tag, "%s is not exported by %s in %s" % (name, lib, os.path.basename(args.sdk.rstrip("/"))))

        for s in args.leak or []:
            if s and s.encode() in data:
                rep.warn(rel, "contains the string %r" % s)

        if args.verbose:
            for sl in slices:
                print("ok    %s[%s] minos %s sdk %s, %d imports, %d dylibs" % (
                    rel, sl.arch, fmt_version(sl.minos or 0), fmt_version(sl.sdk or 0),
                    len(sl.undefined), len(sl.dylibs)))

    print("\nChecked %d Mach-O file(s): %d failure(s), %d warning(s)" % (count, rep.fails, rep.warns))
    if count == 0:
        print("FAIL  no Mach-O files found")
        return 1
    return 1 if rep.fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--min", default="11.0", help="highest allowed minimum macOS version")
    ap.add_argument("--archs", default="arm64,x86_64", help="expected architectures ('' = any)")
    ap.add_argument("--sdk", help="SDK whose .tbd stubs define what may be imported")
    ap.add_argument("--max-sdk", help="highest allowed SDK version recorded in the binaries")
    ap.add_argument("--allow-dylib", action="append", help="regex of an allowed library (replaces defaults)")
    ap.add_argument("--allow-weak", action="append", help="additional allowed weak import")
    ap.add_argument("--leak", action="append", help="string that must not occur in the files (warning)")
    ap.add_argument("--require-signature", action="store_true")
    ap.add_argument("--relative-to", help="print paths relative to this directory")
    ap.add_argument("-v", "--verbose", action="store_true")
    sys.exit(audit(ap.parse_args()))


if __name__ == "__main__":
    main()
