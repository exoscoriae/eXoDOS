# GNU Wget2 2.3.0 — portable universal macOS 11+ bundle

Builds `dist/wget.app/Contents/MacOS/wget`: one universal (arm64 + x86_64)
executable that runs on a fresh macOS 11 or later, with every library built
from source and linked statically. No Homebrew, no MacPorts.

```
./build.sh          # everything: tools, 30 packages x 2 architectures, bundle, audit, smoke test
./test.sh           # runtime tests (run again on a stock macOS 11 VM if you can)
```

Requirements on the build Mac: Apple Silicon, Command Line Tools, Rosetta 2,
`~/SDKs/MacOSX11.3.sdk` (from Xcode 12.5.1; override with `MACOS_SDK=`),
internet access (sources, PyPI for meson/ninja, fresh CA/PSL/HSTS data),
about 6 GB of disk space in `~/wget2-macos-build` (`WORK_DIR=`).

`./build.sh deps|app|audit|clean` run single stages. Logs are in
`$WORK_DIR/logs`. A package is rebuilt when its version, recipe, patches,
compiler flags or embedded data change, together with everything after it.

## How the macOS 11 floor is enforced

1. **Compile and link against the macOS 11.3 SDK** (`-isysroot`) with
   `-mmacosx-version-min=11.0`. Symbols that only exist in newer macOS are not
   in that SDK, so configure scripts see them as missing (gnulib then supplies
   replacements: `strchrnul`, `getrandom`, `explicit_bzero`, ... are absent
   from 11.3) and nothing can link against them.
2. `-Werror=unguarded-availability-new`: an unguarded call to an API marked
   newer than 11.0 (11.1–11.3) is a compile error instead of a silent weak import.
3. x86_64 is compiled natively but configure test programs run under Rosetta,
   so no package is built in cross-compilation mode (no guessed run-time tests).
4. `tools/macho_audit.py` (pure Python, parses Mach-O and the SDK's `.tbd`
   stubs itself) checks every Mach-O in the bundle, every slice: exactly
   arm64+x86_64; minos ≤ 11.0; no chained fixups; only libSystem,
   libresolv and system frameworks linked; no rpaths; no weak imports except
   `___darwin_check_fd_set_overflow`; every imported symbol exported by the
   11.3 SDK for that architecture; signature present; no build paths.
5. `test.sh` runs both slices. The only stronger proof is running it on
   real macOS 11.

## Features

`wget --version` must show (the build fails otherwise):
`+https +ssl/gnutls +ipv6 +iri +large-file +nls +psl +hsts +iconv +idn2 +zlib +lzma +brotlidec +zstd +bzip2 +lzip +http2 +gpgme`

Also enabled: OCSP (+stapling), DANE (`--dane`), TCP Fast Open, xattr
metadata, PCRE2 regexes, plugin support, GnuTLS certificate compression
(zlib/brotli/zstd), post-quantum ML-KEM/ML-DSA in GnuTLS via leancrypto
(opt-in, as in upstream GnuTLS: e.g.
`--secure-protocol="-GROUP-ALL:+GROUP-X25519-MLKEM768:+GROUP-X25519:+GROUP-SECP256R1"`),
translations, bundled GnuPG 2.5 for `--verify-sig`.

`-ntlm -opie` are not implemented by wget2 on any platform. Deliberately left
out:

- **libproxy** (`--enable-libproxy`): with it, wget2 ignores its own
  `--http(s)-proxy`/`--no-proxy` options and wget2rc proxy settings
  (`libwget/http.c`), and it pulls in GLib. Proxies from the environment and
  options keep working without it.
- **p11-kit / PKCS#11 URIs**: needs a module registry outside the bundle; a
  fresh macOS has no PKCS#11 modules.
- **libmicrohttpd**: test suite only.

## Current certificate authorities

The bundle never relies on a CA list frozen at build time:

- **macOS Keychain, read on every run.** GnuTLS' macOS loader is patched
  (`patches/gnutls-3.8.13-macos-keychain-trust.py`) to apply trust settings
  properly. Upstream turns every certificate with trust settings into a trust
  anchor, including ones marked "Never Trust", ignores policy constraints,
  and can `CFRelease(NULL)`. The patch evaluates them like trustd (admin
  settings replace the user's, system settings count only without a
  decision, the first applicable SSL entry decides, Trust Root only for
  self-signed certificates) and puts denied certificates on GnuTLS' block
  list. Stricter than trustd where a global anchor cannot express a setting:
  entries limited to hosts, apps or key usages never create trust, and a
  limited "Never Trust" denies everywhere. A second patch
  (`gnutls-3.8.13-trust-list-blocklist.py`) makes that block list hold: in
  stock GnuTLS a CA file loaded afterwards silently re-adds a blocked root,
  and re-issued certificates of the same CA are not matched.
- **Mozilla CA list, auto-updated.** `patches/wget2-macos/wget_macos_ca.c`:
  the build ships curl.se's `cacert.pem` (checksum-verified at build time);
  at run time the per-user copy in `~/Library/Caches/wget2/` is refreshed over
  HTTPS at most once a day (conditional GET, unconditional at least weekly),
  only when HTTPS is used. A download is verified against the Keychain and
  the list in use, must parse completely (≥100 certificates), may not be
  older than the shipped snapshot nor dated in the future, and must be
  complete by its HTTP framing (or a TLS close_notify). The whole check is
  capped at 10 s on a monotonic clock, enforced in the TLS transport itself
  (a peer trickling bytes cannot stretch one record) and for DNS; failures
  back off 1 h, 2 h, ... 24 h, and the previous list stays in use. The cache
  must be a private directory owned by the user, below directories no other
  user can modify (root ignores `XDG_CACHE_HOME`).
  The newer of the shipped and cached lists is loaded together with the
  Keychain. Env knobs: `WGET_CA_AUTO_UPDATE=0`,
  `WGET_CA_UPDATE_INTERVAL=<hours>`, `WGET_CA_UPDATE_URL=`, `https_proxy`.
  `tests/ca-refresh/run.sh` has 49 tests for it (Linux or macOS, any GnuTLS).

Known limits of the refresh: it is trusted to curl.se's TLS certificate
(as any HTTPS download is) and it uses environment proxies only. It runs
before the downloads start when the command line asks for HTTPS (an
`https://` URL, `--https-only`, `--https-enforce`); otherwise (e.g. an
http:// URL redirected to https) during the first TLS connection, before its
handshake.

This covers both directions on unmaintained systems: macOS 11 no longer gets
root-store updates, but the Mozilla list keeps adding and removing CAs.

## Patches

| Patch | Why |
|---|---|
| `wget2-2.3.0-backports.py` | Upstream fixes after 2.3.0: **08d1af3** HTTPS-via-CONNECT-proxy sent the request in cleartext after a failed TLS handshake (security, 2.1.0–2.3.0); **8d7b977** double free; **acf7f4e** absolute `-P` paths broken in 2.3.0; **f4a1a28** translations never loaded (domain `wget` vs `wget2.mo`); **f46a29c** bogus HSTS parse errors |
| `wget2-2.3.0-macos-bundle.py` | Bundle-relative locale/HSTS/DNSSEC/GnuPG paths, CA list selection and refresh, trust loaded before downloads start (all `#ifdef __APPLE__`) |
| `gnutls-3.8.13-macos-keychain-trust.py` | see above |
| `gnutls-3.8.13-trust-list-blocklist.py` | distrusted CAs stay distrusted when a CA file lists them (see above) |
| `gnutls-3.8.13-dane-root-key-env.py` | DNSSEC root key path settable at run time (`GNUTLS_DANE_ROOT_KEY_FILE`) |
| `unbound-1.26.2-macos-getentropy.py` | libunbound with nettle on macOS calls `getentropy()` without its header (an error with current clang; still upstream) |
| `leancrypto-1.9.1-macos11-sdk.py` | the macOS 11 SDK's `<sys/random.h>` is not self-contained; include its prerequisites first |
| `libgcrypt-1.12.4-darwin-aarch64-asm.py` | 1.12.3+ ARM64 assembly macros use `;` separators, a comment character for Apple's assembler ("Unfinished frame!"); fixed upstream after 1.12.4 |
| `gpgme-2.2.0-no-fallback-paths.py` | gpgme on macOS falls back to `/usr/local/bin`, `/usr/local/MacGPG2/bin` and `/opt/homebrew/bin` when `gpg`/`gpgconf` is not in `PATH`; removed so a Homebrew or GPG Suite install is never picked up behind your back |
| `gnupg-2.5.24-relocatable.py` | GnuPG finds its helpers relative to its own location (no absolute `gpgconf.ctl` needed) |

Build-system workarounds, not patches:

- wget2 2.3.0's `configure` loses `GNULIB_LIBS` (libintl, libiconv,
  CoreFoundation) because of a quoting bug (fixed upstream after 2.3.0). The
  recipe rebuilds it from what configure computed and passes it to `make`.
  (Passing the libraries to configure instead misleads gnulib's checks: they
  find gnulib copies inside the static libraries and assume macOS has
  `mempcpy`, `rawmemchr`, ...; the recipe now asserts they are not found.)
- GnuTLS' DANE probe links with an unset `$oldlibs`. With a static libunbound
  it fails and DANE is disabled without an error. The recipe seeds `oldlibs`.
- All static libraries share one symbol namespace. leancrypto's internals are
  only marked hidden and libunbound's are plain globals, and they clash with
  libgcrypt (`gf_mul`, in GnuPG's dirmngr), GnuTLS's own ARM64 assembly
  (`aes_v8_*`) and wget2 itself (`log_init`). Both libraries are partially
  linked (`ld -r -exported_symbols_list`) so that only their public API
  (`lc_*`; the `ub_*` functions in unbound's `ubsyms.def`) stays global; the
  build stops if anything else does. leancrypto is built without LTO for it.
- libpsl 0.23 compiles in the *base name* of the list it was built from, and
  `psl_latest()` re-reads a file of that name from the current directory if
  it is newer. The recipe blanks that name, so only the built-in list is used.
- gettext 1.0 renamed `--with-included-gettext` to `--with-included-libintl`;
  libintl is configured with `localedir=/usr/share/locale` so no build path
  ends up in the binary (wget2 binds its catalogs to the bundle).
- libgpg-error compiles in its `sysconfdir` (fallback directory for system
  configuration files); it is configured with `/etc` so the build prefix does
  not end up in wget and every GnuPG program.

Every recipe asserts the `config.h` feature macros it expects, so a feature
that is not detected stops the build instead of disappearing.

## Sources

`sources.lock` pins every tarball with a SHA-256/512 taken from FreeBSD ports,
MacPorts or Gentoo. Only leancrypto 1.9.1 has no published checksum; it is
recorded on first download in `checksums.tofu` and enforced afterwards.
Downloads are https-only. Data fetched fresh on each build: Mozilla CA list
(+ `.sha256`), public suffix list, Chromium HSTS preload list (converted with
libhsts' own tool, then checked with libhsts). DNSSEC root anchors are in
`data/`, cross-checked against IANA on each build.

## Layout of the result

```
wget.app/Contents/MacOS/wget                 universal, static, minos 11.0
wget.app/Contents/Resources/ca/cacert.pem    Mozilla CA snapshot
                           /hsts/hsts.dafsa  HSTS preload list
                           /dnssec/          root trust anchors for --dane
                           /locale/          translations
                           /gnupg/{bin,libexec,share}  GnuPG 2.5 (universal)
                           /AppIcon.icns     bundle icon (from data/AppIcon.icns)
                           /man, /licenses, /patches, SOURCES.txt, BUILDINFO.txt
dist/wget2-2.3.0-macos11.0-arm64-x86_64.zip
dist/testdata/                               payloads for test.sh
```

To change the icon, replace `data/AppIcon.icns` and run `./build.sh` again
(only the bundle is re-assembled). Without that file the app gets the
generic icon.

The signature is ad-hoc (`SIGN_IDENTITY=` for a Developer ID). Downloaded
copies need `xattr -dr com.apple.quarantine wget.app` unless notarized.
