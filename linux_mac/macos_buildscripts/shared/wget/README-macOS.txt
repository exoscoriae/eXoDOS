GNU Wget2 for macOS - portable application bundle
==================================================

wget.app runs on macOS 11 (Big Sur) and later, on Apple Silicon and Intel
Macs.  Everything it needs is inside the bundle; it does not use Homebrew,
MacPorts or any other add-on.

Run it from Terminal:

    /path/to/wget.app/Contents/MacOS/wget https://example.com/

or put it on your PATH, e.g.

    sudo mkdir -p /usr/local/bin
    sudo ln -s /Applications/wget.app/Contents/MacOS/wget /usr/local/bin/wget

(a symlink is fine; the program finds its data through it).  The manual is in
Contents/Resources/man/man1/wget2.1:  man Contents/Resources/man/man1/wget2.1

If macOS refuses to run a downloaded copy ("cannot be opened because the
developer cannot be verified"), remove the quarantine flag once:

    xattr -dr com.apple.quarantine /path/to/wget.app


Certificate authorities (HTTPS)
-------------------------------
Every run uses, read fresh at start-up:

  1. the macOS Keychain: Apple's roots and anything you, an administrator or
     a configuration profile added - including "Never Trust" decisions, which
     win over the Mozilla list too (unless --ca-directory replaces the
     system store);
  2. the Mozilla CA list (as published by curl.se).  A copy ships in the app;
     wget keeps a newer copy in ~/Library/Caches/wget2/ and checks for
     updates at most once a day (a small HTTPS request to curl.se, made only
     when wget actually connects to an HTTPS site).

This keeps wget up to date with new and removed certificate authorities even
on Macs whose macOS no longer receives updates.  Settings:

    WGET_CA_AUTO_UPDATE=0         never check for CA list updates
    WGET_CA_UPDATE_INTERVAL=168   check at most weekly (hours; 0 = every run)
    WGET_CA_UPDATE_URL=https://.. use another copy of cacert.pem (e.g. a mirror)
    https_proxy=http://host:port  proxy for the update check (the check does
                                  not use the proxy set in System Preferences)
    --ca-certificate=FILE         use FILE instead of the Mozilla list (the
                                  Keychain still counts)
    --debug                       shows which CA list was used and why

A failed update never stops a download; the previous list stays in use.  The
check takes at most 10 seconds (normally well under one), and after a failure
it waits 1 hour, then 2, 4, ... up to 24 hours before trying again.


Signature verification (--verify-sig)
-------------------------------------
GnuPG is bundled (Contents/Resources/gnupg) and used automatically; it reads
and writes the normal ~/.gnupg keyring.  To import a key:

    /path/to/wget.app/Contents/Resources/gnupg/bin/gpg --import key.asc

Set WGET_GNUPG=system to use a GnuPG installed elsewhere (found via PATH
only; Homebrew and GPG Suite locations are not searched on their own).

As in every wget2 build, --verify-sig only checks files the server sends
with an application/* Content-Type (archives, packages, ...): wget2 then
fetches <url>.sig and verifies it.  Files sent as text/* or image/* are
saved without a signature check.


Other data
----------
HSTS preload list, public suffix list: current as of the build date
(see BUILDINFO.txt).  --dane uses the DNSSEC root keys in
Contents/Resources/dnssec.

Licenses of all included software: Contents/Resources/licenses.  The exact
sources are listed in Contents/Resources/SOURCES.txt and the changes made to
them are in Contents/Resources/patches.
