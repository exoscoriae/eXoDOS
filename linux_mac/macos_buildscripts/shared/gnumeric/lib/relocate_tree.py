#!/usr/bin/env python3
"""Rewrite Mach-O install names inside a staged .app tree so every reference
to the build roots becomes @rpath-relative, and executables get an rpath of
@executable_path/../Resources/lib.

Usage:
    relocate_tree.py <tree> <root1> <root2> [<root3> ...]
    relocate_tree.py --is-macho <file>       (exit 0 if Mach-O, 1 otherwise)

Only Apple's stock tools are used (otool, install_name_tool).
"""
import os
import struct
import subprocess
import sys

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",   # 32-bit
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",   # 64-bit
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",   # fat
}


def is_macho(path):
    try:
        with open(path, "rb") as fh:
            magic = fh.read(4)
    except OSError:
        return False
    if magic not in MACHO_MAGICS:
        return False
    # Java .class files share the CAFEBABE magic; check fat arch count sanity
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        with open(path, "rb") as fh:
            fh.read(4)
            n = struct.unpack(">I", fh.read(4))[0]
            if n == 0 or n > 16:
                return False
    return True


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def otool_lines(flag, path):
    p = run("otool", flag, path)
    if p.returncode != 0:
        return []
    return p.stdout.splitlines()


def map_path(dep, roots):
    """$ROOT/lib/suffix -> @rpath/suffix (for any of the build roots)."""
    for r in roots:
        pfx = r.rstrip("/") + "/lib/"
        if dep.startswith(pfx):
            return "@rpath/" + dep[len(pfx):]
    return None


def get_id(path):
    lines = otool_lines("-D", path)
    return lines[1].strip() if len(lines) >= 2 else None


def get_deps(path):
    deps = []
    for line in otool_lines("-L", path):
        line = line.strip()
        if not line or line.endswith(":"):
            continue
        deps.append(line.split(" (compatibility")[0].strip())
    return deps


def get_rpaths(path):
    rpaths, lines = [], otool_lines("-l", path)
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            for j in range(i, min(i + 4, len(lines))):
                if "path " in lines[j]:
                    rpaths.append(lines[j].split("path ", 1)[1].split(" (offset")[0])
                    break
    return rpaths


def relocate(tree, roots):
    tree = os.path.abspath(tree)
    macos_dir = os.path.join(tree, "Contents", "MacOS")
    changed = 0

    for dirpath, _dirnames, filenames in os.walk(tree):
        for name in filenames:
            f = os.path.join(dirpath, name)
            if os.path.islink(f) or not is_macho(f):
                continue
            os.chmod(f, 0o755)
            args = []

            new_id = map_path(get_id(f) or "", roots)
            if new_id:
                args += ["-id", new_id]

            for dep in get_deps(f):
                new = map_path(dep, roots)
                if new:
                    args += ["-change", dep, new]
                elif dep.startswith("/") and not (
                    dep.startswith("/usr/lib") or dep.startswith("/System/")
                ):
                    print("WARNING: %s links against non-system, non-bundle "
                          "library:\n  %s" % (os.path.relpath(f, tree), dep),
                          file=sys.stderr)

            # scrub any build-time rpaths, add the bundle rpath to executables
            for rp in get_rpaths(f):
                if any(rp.startswith(r) for r in roots) or rp.startswith("/"):
                    args += ["-delete_rpath", rp]
            if dirpath == macos_dir:
                args += ["-add_rpath", "@executable_path/../Resources/lib"]

            if args:
                p = run("install_name_tool", *args, f)
                if p.returncode != 0:
                    sys.exit("install_name_tool failed on %s:\n%s" % (f, p.stderr))
                changed += 1

    print("  rewrote %d Mach-O files" % changed)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--is-macho":
        sys.exit(0 if is_macho(sys.argv[2]) else 1)
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    relocate(sys.argv[1], [os.path.abspath(r) for r in sys.argv[2:]])


if __name__ == "__main__":
    main()
