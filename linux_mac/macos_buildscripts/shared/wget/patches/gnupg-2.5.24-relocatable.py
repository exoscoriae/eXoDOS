#!/usr/bin/env python3
"""GnuPG 2.5.24: make a macOS installation relocatable without gpgconf.ctl.

GnuPG locates its helper programs (gpg-agent, keyboxd, dirmngr, ...) via
directories fixed at configure time.  On Unix it can be relocated with a
gpgconf.ctl file next to the binaries, but that file needs an absolute
"rootdir", which an application bundle that can be moved anywhere cannot
provide.

With GNUPG_MACOS_RELOCATABLE defined (the wget2 bundle build passes it in
CPPFLAGS) and no gpgconf.ctl present, the installation root is taken to be
the parent of the directory holding the running executable -- the same
directory gpgconf.ctl would have been searched in.  bin/, libexec/ and
share/ are then found relative to it; the system configuration directory
becomes <root>/etc/gnupg.  A gpgconf.ctl, if present, still wins.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import patchlib  # noqa: E402

OLD = """      /* Strip one part and expect the file below a bin dir.  */
      *p = 0;
      p = xstrconcat (buffer, "/bin/gpgconf.ctl", NULL);
      xfree (buffer);
      buffer = p;
      parse_gpgconf_ctl (buffer);
      xfree (buffer);
    }
"""

NEW = """      /* Strip one part and expect the file below a bin dir.  */
      *p = 0;
#ifdef GNUPG_MACOS_RELOCATABLE
      {
        char *reloc_root = xstrdup (buffer);
#endif
      p = xstrconcat (buffer, "/bin/gpgconf.ctl", NULL);
      xfree (buffer);
      buffer = p;
      parse_gpgconf_ctl (buffer);
      xfree (buffer);
#ifdef GNUPG_MACOS_RELOCATABLE
        if (!gpgconf_ctl.found)
          {
            /* Relocatable bundle: no gpgconf.ctl, so the installation
             * root is the parent of the directory of this executable.  */
            gpgconf_ctl.rootdir = reloc_root;
            gpgrt_annotate_leaked_object (gpgconf_ctl.rootdir);
            gpgconf_ctl.sysconfdir = xstrconcat (reloc_root, "/etc/gnupg",
                                                 NULL);
            gpgrt_annotate_leaked_object (gpgconf_ctl.sysconfdir);
            gpgconf_ctl.valid = 1;
          }
        else
          xfree (reloc_root);
      }
#endif
    }
"""


def apply(src):
    homedir_c = os.path.join(src, "common", "homedir.c")
    patchlib.require(homedir_c, "macos_myproc_self (1/* with_fallback */);", "macOS executable lookup")
    patchlib.require(homedir_c, "unsigned int found:1;", "gpgconf_ctl.found field")
    patchlib.replace_once(homedir_c, OLD, NEW, "relocatable root without gpgconf.ctl")


if __name__ == "__main__":
    patchlib.main(apply)
