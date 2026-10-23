#!/usr/bin/env python3
"""Local HTTP server for test.sh.

usage: testserver.py PORTFILE TESTDATA_DIR SIGNED_DIR

  /enc/<encoding>   payload.txt sent with "Content-Encoding: <encoding>"
                    (gzip deflate bzip2 xz br zstd lzip)
  /signed.txt       a file, and /signed.txt.sig its detached OpenPGP signature
  /tampered.txt     same signature, different content (/tampered.txt.sig)

The chosen port is written to PORTFILE.
"""

import http.server
import os
import socketserver
import sys

ENC_FILES = {
    "gzip": "payload.gz", "deflate": "payload.deflate", "bzip2": "payload.bz2",
    "xz": "payload.xz", "br": "payload.br", "zstd": "payload.zst", "lzip": "payload.lz",
}


def main():
    portfile, testdata, signed = sys.argv[1:4]

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def send(self, body, ctype="application/octet-stream", enc=None):
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            if enc:
                self.send_header("Content-Encoding", enc)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            p = self.path.split("?")[0]
            if p.startswith("/enc/") and p[5:] in ENC_FILES:
                with open(os.path.join(testdata, ENC_FILES[p[5:]]), "rb") as f:
                    return self.send(f.read(), "text/plain", p[5:])
            name = os.path.basename(p)
            if name in ("signed.txt", "signed.txt.sig", "tampered.txt", "tampered.txt.sig"):
                path = os.path.join(signed, name)
                if os.path.exists(path):
                    with open(path, "rb") as f:
                        # wget2 only looks for <file>.sig when the file itself
                        # is served as application/*
                        ctype = ("application/pgp-signature" if name.endswith(".sig")
                                 else "application/octet-stream")
                        return self.send(f.read(), ctype)
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    srv = S(("127.0.0.1", 0), H)
    with open(portfile + ".tmp", "w") as f:
        f.write(str(srv.server_address[1]))
    os.rename(portfile + ".tmp", portfile)
    srv.serve_forever()


if __name__ == "__main__":
    main()
