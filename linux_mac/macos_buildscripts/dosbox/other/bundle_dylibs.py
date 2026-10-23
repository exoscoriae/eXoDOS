#!/usr/bin/env python3
"""
bundle_dylibs.py — Walk a Mach-O binary's dylib dependency graph and copy
every non-system dylib into an app bundle's Frameworks directory, rewriting
install names so the app is fully self-contained.

Called by package_macos.sh after staging the DOSBox binary.

After this script runs:
  - MyApp.app/Contents/Frameworks/ contains every non-system dylib the
    binary (or any dylib it loads) depends on.
  - Every copied dylib's LC_ID_DYLIB is rewritten to @rpath/libfoo.dylib.
  - Every LC_LOAD_DYLIB reference to a non-system dylib in the binary and
    in every copied dylib is rewritten to @rpath/libfoo.dylib.
  - The main executable gets an @executable_path/../Frameworks rpath.
  - Nothing references /opt/homebrew, /usr/local, or the local deps-prefix
    at runtime.

Usage:
    python3 bundle_dylibs.py <executable> <frameworks-dir> \
        [--also-bundle <dylib>]... [extra-search-dir...]

    --also-bundle <path>   A dylib that must be bundled into Frameworks/
                           even though it is not a static dependency of the
                           executable. Use for libraries loaded dynamically
                           via dlopen() (e.g., libSDL2 when the binary links
                           against the sdl12-compat shim, which dlopens SDL2
                           at runtime and therefore shows no LC_LOAD_DYLIB
                           entry in `otool -L`).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


# Paths considered "system" — we DO NOT bundle these; they're part of macOS
# and guaranteed to exist on any supported system. Anything else we copy.
SYSTEM_PREFIXES = (
    '/System/',
    '/usr/lib/',         # libSystem, libc++, etc.
    '/Library/Frameworks/',  # Only Apple's signed frameworks
    '/Applications/Xcode.app/',
)

# Load-command directives that resolve relative to the loader — already OK.
SELF_REFERENTIAL_PREFIXES = (
    '@rpath/',
    '@executable_path/',
    '@loader_path/',
)


def run(cmd, check=True):
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.stderr.write(f"ERROR: {' '.join(cmd)}\n{result.stderr}\n")
        sys.exit(1)
    return result


def otool_L(path):
    """Return list of (dylib_path, compat_ver, current_ver) for a Mach-O file."""
    out = run(['otool', '-L', str(path)]).stdout
    refs = []
    for line in out.splitlines()[1:]:   # first line is the path itself
        line = line.strip()
        if not line:
            continue
        m = re.match(r'^(.+?)\s+\(compatibility version .+\)$', line)
        if m:
            refs.append(m.group(1).strip())
    return refs


def otool_id(path):
    """Return the LC_ID_DYLIB install name of a dylib, or None."""
    out = run(['otool', '-D', str(path)]).stdout.splitlines()
    # otool -D output:
    #   path/to/lib.dylib:
    #   @rpath/lib.dylib
    if len(out) >= 2:
        return out[1].strip()
    return None


def is_system(dylib_path):
    return any(dylib_path.startswith(p) for p in SYSTEM_PREFIXES)


def is_self_referential(dylib_path):
    return any(dylib_path.startswith(p) for p in SELF_REFERENTIAL_PREFIXES)


def resolve_dylib(ref, search_dirs, loader_path):
    """Resolve an otool dylib reference to an actual file on disk."""
    # @rpath / @loader_path / @executable_path references: try search dirs.
    if ref.startswith('@rpath/'):
        name = ref[len('@rpath/'):]
        for d in search_dirs:
            cand = os.path.join(d, name)
            if os.path.exists(cand):
                return os.path.realpath(cand)
        # Also try any subdir of our deps prefix
        return None
    if ref.startswith('@loader_path/'):
        cand = os.path.normpath(os.path.join(loader_path, ref[len('@loader_path/'):]))
        return os.path.realpath(cand) if os.path.exists(cand) else None
    if ref.startswith('@executable_path/'):
        # executable_path is always the main MacOS binary's dir.
        # We don't have it at this point — caller injected search_dirs.
        name = ref[len('@executable_path/'):]
        for d in search_dirs:
            cand = os.path.join(d, os.path.basename(name))
            if os.path.exists(cand):
                return os.path.realpath(cand)
        return None

    # Absolute path: just verify it exists.
    if os.path.isabs(ref):
        return os.path.realpath(ref) if os.path.exists(ref) else None

    # Relative: search each search dir
    for d in search_dirs:
        cand = os.path.join(d, ref)
        if os.path.exists(cand):
            return os.path.realpath(cand)
    return None


def copy_and_stage(real_src, frameworks_dir):
    """Copy a dylib into Frameworks with its basename. Return staged path."""
    basename = os.path.basename(real_src)
    dest = os.path.join(frameworks_dir, basename)
    if not os.path.exists(dest):
        shutil.copy2(real_src, dest)
        os.chmod(dest, 0o755)
    return dest


def bundle(executable, frameworks_dir, extra_search_dirs, also_bundle=()):
    """Recursively copy every non-system dylib into Frameworks and fix names.

    also_bundle: iterable of absolute paths to dylibs that must be bundled
    even though they are not static deps of the executable (e.g. libraries
    loaded via dlopen() at runtime).
    """
    frameworks_dir = os.path.abspath(frameworks_dir)
    os.makedirs(frameworks_dir, exist_ok=True)

    # Track everything we've processed; key = real source path
    processed = {}   # real_src -> staged_path

    # Queue of Mach-O files to scan: (path_on_disk, loader_dir)
    queue = [(os.path.abspath(executable), os.path.dirname(os.path.abspath(executable)))]

    search_dirs = [frameworks_dir] + [os.path.abspath(d) for d in extra_search_dirs]

    # Pre-stage explicit --also-bundle dylibs so the graph walk sees them.
    # This is how we handle dlopen()-loaded libs like libSDL2 (pulled in by
    # the sdl12-compat shim at runtime, not via LC_LOAD_DYLIB).
    for extra in also_bundle:
        real = os.path.realpath(extra)
        if not os.path.exists(real):
            sys.stderr.write(f"WARN: --also-bundle path not found: {extra}\n")
            continue
        if real in processed:
            continue
        staged = copy_and_stage(real, frameworks_dir)
        processed[real] = staged
        new_ref = f'@rpath/{os.path.basename(real)}'
        run(['install_name_tool', '-id', new_ref, staged])
        queue.append((staged, frameworks_dir))

    while queue:
        path, loader_dir = queue.pop(0)
        refs = otool_L(path)

        # Build list of changes to apply with install_name_tool in one pass.
        changes = []   # list of (old, new)

        for ref in refs:
            if is_system(ref):
                continue

            # @rpath etc. references are OK if they resolve inside Frameworks.
            # But if an @rpath reference currently resolves to a library
            # OUTSIDE Frameworks (e.g., a deps-prefix copy), we still need to
            # bundle the target and normalize the reference.
            resolved = resolve_dylib(ref, search_dirs + [loader_dir], loader_dir)

            if resolved is None:
                # If this is already a self-referential name inside Frameworks,
                # tolerate it; otherwise warn.
                if ref.startswith('@rpath/'):
                    staged_candidate = os.path.join(frameworks_dir, os.path.basename(ref))
                    if os.path.exists(staged_candidate):
                        continue
                sys.stderr.write(f"WARN: cannot resolve dylib ref {ref!r} from {path}\n")
                continue

            # Skip if this is the library itself (e.g., its own LC_ID_DYLIB).
            if os.path.realpath(resolved) == os.path.realpath(path):
                continue

            basename = os.path.basename(resolved)
            new_ref = f'@rpath/{basename}'

            # Stage the dylib into Frameworks if we haven't already.
            if resolved not in processed:
                staged = copy_and_stage(resolved, frameworks_dir)
                processed[resolved] = staged
                # Fix its own ID to @rpath/basename.
                run(['install_name_tool', '-id', new_ref, staged])
                # Recursively scan its dependencies too.
                queue.append((staged, frameworks_dir))

            # If the reference isn't already @rpath/basename, rewrite it.
            if ref != new_ref:
                changes.append((ref, new_ref))

        # Apply all rewrites to this file.
        for old, new in changes:
            run(['install_name_tool', '-change', old, new, path])

    return sorted(processed.values())


def ensure_rpath(binary, rpath):
    """Add an LC_RPATH to a Mach-O binary if it isn't already there."""
    # Check current rpaths via otool -l
    out = run(['otool', '-l', binary]).stdout
    # Parse LC_RPATH entries
    has_it = False
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if 'cmd LC_RPATH' in line:
            # next few lines contain `path <value>`
            for j in range(i, min(i + 6, len(lines))):
                m = re.match(r'\s*path\s+(\S+)\s*\(', lines[j])
                if m and m.group(1) == rpath:
                    has_it = True
                    break
        if has_it:
            break
    if not has_it:
        run(['install_name_tool', '-add_rpath', rpath, binary])


def strip_bogus_rpaths(binary, bad_prefixes):
    """Remove any LC_RPATH that points into a build-time location."""
    out = run(['otool', '-l', binary]).stdout
    lines = out.splitlines()
    to_remove = []
    for i, line in enumerate(lines):
        if 'cmd LC_RPATH' in line:
            for j in range(i, min(i + 6, len(lines))):
                m = re.match(r'\s*path\s+(\S+)\s*\(', lines[j])
                if m:
                    p = m.group(1)
                    if any(p.startswith(bp) for bp in bad_prefixes):
                        to_remove.append(p)
                    break
    for p in to_remove:
        run(['install_name_tool', '-delete_rpath', p, binary], check=False)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("Usage: bundle_dylibs.py <executable> <frameworks-dir> "
                         "[--also-bundle <dylib>]... [extra-search-dir...]\n")
        sys.exit(2)

    executable = sys.argv[1]
    frameworks_dir = sys.argv[2]

    # Parse trailing args: --also-bundle <path> flags and plain search dirs.
    rest = sys.argv[3:]
    also_bundle = []
    extra_dirs = []
    i = 0
    while i < len(rest):
        if rest[i] == '--also-bundle':
            if i + 1 >= len(rest):
                sys.stderr.write("ERROR: --also-bundle requires a path argument\n")
                sys.exit(2)
            also_bundle.append(rest[i + 1])
            i += 2
        else:
            extra_dirs.append(rest[i])
            i += 1

    if not os.path.isfile(executable):
        sys.stderr.write(f"ERROR: executable not found: {executable}\n")
        sys.exit(1)

    # 1) Make sure executable can find dylibs relative to the bundle layout.
    ensure_rpath(executable, '@executable_path/../Frameworks')

    # 2) Recursively bundle and rewrite everything.
    staged = bundle(executable, frameworks_dir, extra_dirs, also_bundle=also_bundle)

    # 3) Remove any LC_RPATH entries that reference build-time paths (e.g.
    #    the deps-prefix). Otherwise the app keeps a cosmetic pointer to a
    #    path that doesn't exist on the target machine (harmless, but ugly).
    cleanup_prefixes = tuple(extra_dirs) + ('/opt/homebrew', '/usr/local/opt',
                                            '/opt/local', '/usr/local/Cellar')
    strip_bogus_rpaths(executable, cleanup_prefixes)
    for s in staged:
        strip_bogus_rpaths(s, cleanup_prefixes)

    # 4) Report.
    print(f"  Bundled {len(staged)} dylib(s) into {frameworks_dir}:")
    for s in staged:
        size_kb = os.path.getsize(s) // 1024
        print(f"    {os.path.basename(s)}  ({size_kb} KB)")

    # 5) Sanity check: no residual references to deps-prefix or homebrew.
    bad_refs = []
    for path in [executable] + staged:
        for ref in otool_L(path):
            if any(ref.startswith(bp) for bp in cleanup_prefixes):
                bad_refs.append((path, ref))
    if bad_refs:
        print()
        print("WARNING: Some binaries still reference build-time paths:")
        for p, r in bad_refs:
            print(f"  {os.path.basename(p)} -> {r}")
        sys.exit(1)


if __name__ == '__main__':
    main()
