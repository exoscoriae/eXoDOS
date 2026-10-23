#!/usr/bin/env python3
"""Test HTTPS server + CONNECT proxy for the CA-refresh tests.

usage: server.py https PORT CERT KEY DATADIR LOG
       server.py proxy PORT LOG
       server.py drip PORT CERT KEY BODYFILE body|hs

https paths:
  /new       200 + Last-Modified, honours If-Modified-Since (304)
  /chunked   same body, Transfer-Encoding: chunked
  /old       a bundle that is older than the snapshot
  /bad       not a CA bundle
  /short     Content-Length larger than the body, then close
  /500       server error
  /future    a bundle dated 2199
  /mid       a bundle between the snapshot and /new
  /keepalive Content-Length body, then the connection stays open (20 s)
  /noframe   no Content-Length / chunking, TCP close without TLS close_notify
  /noframe-clean  same, but with close_notify
  /trickle   Content-Length body sent very slowly
  /hints     "103 Early Hints" before the 200 response

drip: every byte of the TLS stream is released slowly (body: the response,
hs: the handshake), so single TLS records take far longer than any
per-read timeout.
"""

import http.server
import os
import select
import socket
import socketserver
import ssl
import sys
import threading
import time

LAST_MODIFIED = "Tue, 03 Mar 2026 03:12:09 GMT"


def log(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")


def https_server(port, cert, key, datadir, logpath):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def body(self, name):
            with open(os.path.join(datadir, name), "rb") as f:
                return f.read()

        def do_GET(self):
            ims = self.headers.get("If-Modified-Since")
            log(logpath, "GET %s ims=%s ua=%s" % (self.path, ims, self.headers.get("User-Agent")))
            if self.path == "/new":
                if ims == LAST_MODIFIED:
                    self.send_response(304)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Last-Modified", LAST_MODIFIED)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            elif self.path == "/chunked":
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for i in range(0, len(b), 7777):
                    part = b[i:i + 7777]
                    self.wfile.write(b"%x;ext=1\r\n" % len(part) + part + b"\r\n")
                self.wfile.write(b"0\r\nX-Trailer: y\r\n\r\n")
            elif self.path == "/keepalive":
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
                self.wfile.flush()
                time.sleep(20)
            elif self.path in ("/noframe", "/noframe-clean"):
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b)
                self.wfile.flush()
                self.close_connection = True
                if self.path == "/noframe-clean":
                    try:
                        self.connection.unwrap()
                    except Exception:
                        pass
            elif self.path == "/trickle":
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                try:
                    for i in range(0, len(b), 1000):
                        self.wfile.write(b[i:i + 1000])
                        self.wfile.flush()
                        time.sleep(0.4)
                except Exception:
                    pass
            elif self.path == "/hints":
                b = self.body("new.pem")
                self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </x.css>; rel=preload\r\n\r\n")
                self.send_response(200)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            elif self.path in ("/old", "/bad", "/future", "/mid"):
                b = self.body(self.path[1:] + ".pem")
                self.send_response(200)
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
            elif self.path == "/short":
                b = self.body("new.pem")
                self.send_response(200)
                self.send_header("Content-Length", str(len(b) + 1000))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b)
                self.close_connection = True
            else:
                self.send_response(500)
                self.send_header("Content-Length", "0")
                self.end_headers()

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    srv = S(("127.0.0.1", port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


def proxy_server(port, logpath):
    class P(socketserver.StreamRequestHandler):
        def handle(self):
            head = b""
            while b"\r\n\r\n" not in head:
                c = self.connection.recv(1)
                if not c:
                    return
                head += c
            text = head.decode("latin-1")
            log(logpath, "PROXY " + " | ".join(text.strip().split("\r\n")))
            target = text.split()[1]
            host, port_ = target.rsplit(":", 1)
            up = socket.create_connection((host.strip("[]"), int(port_)))
            self.connection.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            socks = [self.connection, up]
            while True:
                r, _, _ = select.select(socks, [], [], 30)
                if not r:
                    break
                for s in r:
                    d = s.recv(65536)
                    if not d:
                        up.close()
                        return
                    (up if s is self.connection else self.connection).sendall(d)

    class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
        daemon_threads = True
        allow_reuse_address = True

    S(("127.0.0.1", port), P).serve_forever()


def drip_server(port, cert, key, bodyfile, mode):
    with open(bodyfile, "rb") as f:
        body = f.read()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    chunk, delay = (50, 0.5) if mode == "hs" else (200, 0.5)

    def pump(sock, out, slow):
        data = out.read()
        if not slow:
            sock.sendall(data)
            return
        for i in range(0, len(data), chunk):
            sock.sendall(data[i:i + chunk])
            time.sleep(delay)

    def handle(sock):
        inc, out = ssl.MemoryBIO(), ssl.MemoryBIO()
        obj = ctx.wrap_bio(inc, out, server_side=True)
        try:
            while True:
                try:
                    obj.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    pump(sock, out, mode == "hs")
                    d = sock.recv(65536)
                    if not d:
                        return
                    inc.write(d)
            pump(sock, out, False)
            req = b""
            while b"\r\n\r\n" not in req:
                try:
                    req += obj.read(65536)
                except ssl.SSLWantReadError:
                    pump(sock, out, False)
                    d = sock.recv(65536)
                    if not d:
                        return
                    inc.write(d)
            obj.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
            pump(sock, out, True)
        except Exception:
            pass
        finally:
            sock.close()

    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(("127.0.0.1", port))
    ls.listen(5)
    while True:
        c, _ = ls.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


if __name__ == "__main__":
    if sys.argv[1] == "https":
        https_server(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    elif sys.argv[1] == "drip":
        drip_server(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    else:
        proxy_server(int(sys.argv[2]), sys.argv[3])
