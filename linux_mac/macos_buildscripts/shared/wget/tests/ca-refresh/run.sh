#!/bin/bash
# Functional tests for patches/wget2-macos/wget_macos_ca.c against a local
# HTTPS server and CONNECT proxy.  Needs: cc, openssl, python3 and GnuTLS
# headers/library given via GNUTLS_CFLAGS / GNUTLS_LIBS, e.g.
#   GNUTLS_CFLAGS="$(pkgconf --cflags gnutls)" GNUTLS_LIBS="$(pkgconf --static --libs gnutls)" ./run.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../patches/wget2-macos"
T="$(mktemp -d "${TMPDIR:-/tmp}/ca-refresh-test.XXXXXX")"
PASS=0; FAILS=0
ok()   { PASS=$((PASS+1)); echo "  ok   $*"; }
bad()  { FAILS=$((FAILS+1)); echo "  FAIL $*"; }
cleanup() {
  for p in ${SPID:-} ${PPID2:-} ${DPID1:-} ${DPID2:-}; do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

# ---- certificates and bundles
cd "$T"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr -subj "/CN=localhost" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > ext.cnf
openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out srv.pem -days 2 -extfile ext.cnf >/dev/null 2>&1
# 110 throw-away CA certificates make up the body of the bundles
for i in $(seq 1 110); do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout /dev/null -days 2 -subj "/CN=Filler $i" 2>/dev/null
done > filler.pem
mkbundle() { # date file [extra-pem]
  { printf '##\n## Bundle of CA Root Certificates\n##\n## Certificate data from Mozilla as of: %s\n##\n\n' "$1"
    cat filler.pem; [ -n "${3:-}" ] && cat "$3"; } > "$2"; }
mkdir data
mkbundle "Mon Jan  5 03:12:09 2026 GMT" snapshot.pem ca.pem
mkbundle "Mon Jan  5 03:12:09 2026 GMT" snapshot-untrusted.pem
mkbundle "Tue Mar  3 03:12:09 2026 GMT" data/new.pem ca.pem
mkbundle "Sun Jun  1 03:12:09 2025 GMT" data/old.pem ca.pem
mkbundle "Tue Feb  3 03:12:09 2026 GMT" data/mid.pem ca.pem
mkbundle "Fri Jan  3 03:12:09 2199 GMT" data/future.pem ca.pem
printf '<html>not a bundle</html>\n' > data/bad.pem
head -c 3000 data/new.pem > trunc.pem

# ---- build the harness
cc -std=gnu99 -O1 -g -pthread -Wall -Wextra -Werror -Wno-format-nonliteral ${EXTRA_CFLAGS:-} ${GNUTLS_CFLAGS:-} -I"$SRC" \
   -o harness "$HERE/harness.c" ${GNUTLS_LIBS:-} || { echo "cannot build harness"; exit 1; }

# ---- servers
PORT=$((20000 + RANDOM % 20000)); PPORT=$((PORT + 1)); DPORT1=$((PORT + 2)); DPORT2=$((PORT + 3))
python3 "$HERE/server.py" https $PORT srv.pem srv.key data server.log & SPID=$!
python3 "$HERE/server.py" proxy $PPORT proxy.log & PPID2=$!
python3 "$HERE/server.py" drip $DPORT1 srv.pem srv.key data/new.pem body & DPID1=$!
python3 "$HERE/server.py" drip $DPORT2 srv.pem srv.key data/new.pem hs & DPID2=$!
sleep 1.5

run() { # name url [env...] -> output in $OUT
  local name=$1 url=$2; shift 2
  OUT=$(env -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
        XDG_CACHE_HOME="$T/cache-$CACHE" TEST_SNAPSHOT="$T/snapshot.pem" WGET_CA_UPDATE_URL="$url" \
        "$@" ./harness 1 2>&1)
  echo "$OUT" > "out-$name.txt"
}
reqs() { grep -c "^GET" server.log 2>/dev/null || echo 0; }
# portable (GNU/BSD) mtime helpers
setage() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
age() { python3 -c 'import os,sys,time; print(int(time.time()-os.stat(sys.argv[1]).st_mtime))' "$1"; }
C="$T/cache-A/wget2"

echo "== initial download"
CACHE=A; run first "https://localhost:$PORT/new"
grep -q "RESULT $C/cacert.pem" <<<"$OUT" && ok "uses downloaded bundle" || bad "first run: $OUT"
cmp -s "$C/cacert.pem" data/new.pem && ok "cache content identical" || bad "cache content differs"
[ -f "$C/cacert.pem.checked" ] && ok "checked stamp" || bad "no checked stamp"
grep -q "Tue, 03 Mar 2026" "$C/cacert.pem.lastmod" && ok "Last-Modified stored" || bad "lastmod missing"

echo "== within interval: no network"
n=$(reqs); CACHE=A; run second "https://localhost:$PORT/new"
[ "$(reqs)" = "$n" ] && ok "no request" || bad "unexpected request"
grep -q "RESULT $C/cacert.pem" <<<"$OUT" && ok "still uses cache" || bad "$OUT"

echo "== interval 0: conditional request"
CACHE=A; run third "https://localhost:$PORT/new" WGET_CA_UPDATE_INTERVAL=0
tail -1 server.log | grep -q "ims=Tue, 03 Mar 2026 03:12:09 GMT" && ok "If-Modified-Since sent" || bad "no IMS: $(tail -1 server.log)"
grep -q "bundle unchanged" <<<"$OUT" && ok "304 handled" || bad "$OUT"

echo "== rollback behind the shipped snapshot refused"
CACHE=A; run old "https://localhost:$PORT/old" WGET_CA_UPDATE_INTERVAL=0
grep -q "older bundle" <<<"$OUT" && cmp -s "$C/cacert.pem" data/new.pem && ok "older bundle rejected" || bad "$OUT"

echo "== future-dated bundle refused"
CACHE=A; run future "https://localhost:$PORT/future" WGET_CA_UPDATE_INTERVAL=0
grep -q "dated in the future" <<<"$OUT" && cmp -s "$C/cacert.pem" data/new.pem && ok "future date rejected" || bad "$OUT"
rm -f "$C/cacert.pem.failed"

echo "== weekly unconditional download"
setage "$C/cacert.pem" $((8 * 86400))
CACHE=A; run weekly "https://localhost:$PORT/new" WGET_CA_UPDATE_INTERVAL=0
tail -1 server.log | grep -q "ims=None" && ok "no If-Modified-Since for a week-old copy" || bad "$(tail -1 server.log)"
[ "$(age "$C/cacert.pem")" -lt 60 ] && cmp -s "$C/cacert.pem" data/new.pem && ok "copy re-downloaded" || bad "$OUT"

echo "== invalid data refused, failure backoff"
rm -f "$C/cacert.pem.failed"
CACHE=A; run badd "https://localhost:$PORT/bad" WGET_CA_UPDATE_INTERVAL=0
grep -q "not a valid Mozilla CA bundle" <<<"$OUT" && cmp -s "$C/cacert.pem" data/new.pem && ok "garbage rejected, cache kept" || bad "$OUT"
[ -f "$C/cacert.pem.failed" ] && ok "failure stamp" || bad "no failure stamp"
rm -f "$C/cacert.pem.checked"; n=$(reqs)
CACHE=A; run backoff "https://localhost:$PORT/new"
[ "$(reqs)" = "$n" ] && ok "backoff after failure" || bad "retried during backoff"

echo "== truncated body refused"
CACHE=B; run short "https://localhost:$PORT/short"
grep -q "incomplete body" <<<"$OUT" && [ ! -f "$T/cache-B/wget2/cacert.pem" ] && ok "short body rejected" || bad "$OUT"
grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "falls back to snapshot" || bad "$OUT"

echo "== chunked transfer"
CACHE=C; run chunked "https://localhost:$PORT/chunked"
cmp -s "$T/cache-C/wget2/cacert.pem" data/new.pem && ok "chunked body decoded" || bad "$OUT"

echo "== HTTP error"
CACHE=D; run e500 "https://localhost:$PORT/500"
grep -q "status 500" <<<"$OUT" && grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "500 ignored" || bad "$OUT"

echo "== untrusted server certificate"
CACHE=E; OUT=$(env XDG_CACHE_HOME="$T/cache-E" TEST_SNAPSHOT="$T/snapshot-untrusted.pem" \
  WGET_CA_UPDATE_URL="https://localhost:$PORT/new" ./harness 1 2>&1)
grep -qi "handshake.*failed" <<<"$OUT" && [ ! -f "$T/cache-E/wget2/cacert.pem" ] && ok "TLS verification enforced" || bad "$OUT"

echo "== server down"
CACHE=F; start=$(date +%s); run down "https://localhost:1/new"
[ $(( $(date +%s) - start )) -lt 8 ] && grep -q "cannot connect" <<<"$OUT" && ok "fast failure" || bad "$OUT"

echo "== server ignores Connection: close"
CACHE=O; start=$(date +%s); run keepalive "https://localhost:$PORT/keepalive"
[ $(( $(date +%s) - start )) -lt 5 ] && cmp -s "$T/cache-O/wget2/cacert.pem" data/new.pem && ok "done at Content-Length" || bad "$OUT"

echo "== unframed body: TLS close_notify required"
CACHE=P; run noframe "https://localhost:$PORT/noframe"
grep -q "without TLS close_notify" <<<"$OUT" && [ ! -f "$T/cache-P/wget2/cacert.pem" ] && ok "truncation-prone body rejected" || bad "$OUT"
CACHE=Q; run noframeclean "https://localhost:$PORT/noframe-clean"
cmp -s "$T/cache-Q/wget2/cacert.pem" data/new.pem && ok "properly closed body accepted" || bad "$OUT"

echo "== overall time limit"
CACHE=R; start=$(date +%s); run trickle "https://localhost:$PORT/trickle"
el=$(( $(date +%s) - start ))
[ "$el" -ge 8 ] && [ "$el" -le 14 ] && grep -q "no complete answer" <<<"$OUT" && ok "slow transfer aborted after ${el}s" || bad "${el}s: $OUT"
grep -qx 1 "$T/cache-R/wget2/cacert.pem.failed" && ok "failure counted" || bad "failure count: $(cat "$T/cache-R/wget2/cacert.pem.failed" 2>&1)"
CACHE=S2; start=$(date +%s); run dripbody "https://localhost:$DPORT1/new"
el=$(( $(date +%s) - start ))
[ "$el" -le 13 ] && grep -q "no complete answer" <<<"$OUT" && [ ! -f "$T/cache-S2/wget2/cacert.pem" ] && ok "byte-trickled TLS record aborted after ${el}s" || bad "${el}s: $OUT"
CACHE=S3; start=$(date +%s); run driphs "https://localhost:$DPORT2/new"
el=$(( $(date +%s) - start ))
[ "$el" -le 13 ] && grep -q "handshake.*failed" <<<"$OUT" && ok "byte-trickled handshake aborted after ${el}s" || bad "${el}s: $OUT"
CACHE=S; start=$(date +%s); run gai "https://localhost:$PORT/new" TEST_GAI_DELAY=15
el=$(( $(date +%s) - start ))
[ "$el" -le 13 ] && grep -q "name lookup for localhost timed out" <<<"$OUT" && ok "hanging name lookup abandoned after ${el}s" || bad "${el}s: $OUT"

echo "== interim responses"
CACHE=S4; run hints "https://localhost:$PORT/hints"
cmp -s "$T/cache-S4/wget2/cacert.pem" data/new.pem && ok "103 Early Hints skipped" || bad "$OUT"

echo "== exponential failure backoff"
F="$T/cache-R/wget2/cacert.pem.failed"
printf '2\n' > "$F"; setage "$F" 5400; n=$(reqs)
CACHE=R; run backoff2 "https://localhost:$PORT/new"
[ "$(reqs)" = "$n" ] && ok "2 failures: still waiting after 90 min" || bad "retried too early"
printf '1\n' > "$F"; setage "$F" 5400
CACHE=R; run backoff1 "https://localhost:$PORT/new"
[ "$(reqs)" -gt "$n" ] && [ ! -f "$F" ] && ok "1 failure: retried after 90 min, stamp cleared" || bad "$OUT"

echo "== newer genuine data than the cache is not required"
CACHE=T; run tnew "https://localhost:$PORT/new"
CACHE=T; run tmid "https://localhost:$PORT/mid" WGET_CA_UPDATE_INTERVAL=0
cmp -s "$T/cache-T/wget2/cacert.pem" data/mid.pem && ok "server's current list replaces a newer cached one" || bad "$OUT"

echo "== cache directory must be private"
mkdir -p "$T/cache-U/wget2"; chmod 777 "$T/cache-U/wget2"; n=$(reqs)
CACHE=U; run unsafe "https://localhost:$PORT/new"
[ "$(reqs)" = "$n" ] && grep -q "not a private" <<<"$OUT" && grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "world-writable cache ignored" || bad "$OUT"
mkdir -p "$T/cache-V"; ln -s "$T/cache-A/wget2" "$T/cache-V/wget2"
CACHE=V; run symlink "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0
grep -q "not a private" <<<"$OUT" && grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "symlinked cache ignored" || bad "$OUT"
mkdir -p "$T/cache-W/wget2"; cp data/future.pem "$T/cache-W/wget2/cacert.pem"
CACHE=W; run futurecache "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0
grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "future-dated cache ignored" || bad "$OUT"
mkdir -p "$T/open"; chmod 777 "$T/open"
OUT=$(env XDG_CACHE_HOME="$T/open/xdg" TEST_SNAPSHOT="$T/snapshot.pem" WGET_CA_AUTO_UPDATE=0 ./harness 1 2>&1)
grep -q "not a private" <<<"$OUT" && grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "cache below a world-writable directory ignored" || bad "$OUT"
mkdir -p "$T/sticky"; chmod 1777 "$T/sticky"
OUT=$(env XDG_CACHE_HOME="$T/sticky/xdg" TEST_SNAPSHOT="$T/snapshot.pem" WGET_CA_UPDATE_URL="https://localhost:$PORT/new" ./harness 1 2>&1)
cmp -s "$T/sticky/xdg/wget2/cacert.pem" data/new.pem && ok "cache below a sticky directory (like /tmp) used" || bad "$OUT"
CACHE=X; run asroot "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0 TEST_AS_ROOT=1 TEST_ROOT_HOME="$T/roothome"
[ -d "$T/roothome/Library/Caches/wget2" ] && [ ! -e "$T/cache-X" ] && ok "root ignores XDG_CACHE_HOME" || bad "$OUT"

echo "== disabled"
n=$(reqs); CACHE=G; run off "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0
[ "$(reqs)" = "$n" ] && grep -q "disabled" <<<"$OUT" && ok "WGET_CA_AUTO_UPDATE=0" || bad "$OUT"

echo "== proxy with credentials"
CACHE=H; run proxy "https://localhost:$PORT/new" https_proxy="http://us%3Aer:p%40ss@127.0.0.1:$PPORT"
grep -q "CONNECT localhost:$PORT" proxy.log && ok "CONNECT used" || bad "no CONNECT: $OUT"
# base64("us:er:p@ss") = dXM6ZXI6cEBzcw==
grep -q "Proxy-Authorization: Basic dXM6ZXI6cEBzcw==" proxy.log && ok "proxy credentials decoded" || bad "$(cat proxy.log)"
cmp -s "$T/cache-H/wget2/cacert.pem" data/new.pem && ok "download through proxy" || bad "$OUT"

echo "== no_proxy bypass"
CACHE=I; run noproxy "https://localhost:$PORT/new" https_proxy="http://127.0.0.1:1" no_proxy="example.org, .localhost,localhost"
cmp -s "$T/cache-I/wget2/cacert.pem" data/new.pem && ok "no_proxy honoured" || bad "$OUT"

echo "== concurrent refresh is skipped while locked"
mkdir -p "$T/cache-J/wget2"; n=$(reqs)
python3 -c "import fcntl,time,sys; f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(3)" "$T/cache-J/wget2/.lock" & LP=$!
sleep 0.5; CACHE=J; run locked "https://localhost:$PORT/new"; wait $LP
[ "$(reqs)" = "$n" ] && grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "lock respected" || bad "$OUT"

echo "== newer snapshot wins over an older cache"
mkdir -p "$T/cache-K/wget2"; cp data/old.pem "$T/cache-K/wget2/cacert.pem"
CACHE=K; run choose "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0
grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "snapshot chosen" || bad "$OUT"

echo "== corrupt cache ignored"
mkdir -p "$T/cache-L/wget2"; cp trunc.pem "$T/cache-L/wget2/cacert.pem"
CACHE=L; run corrupt "https://localhost:$PORT/new" WGET_CA_AUTO_UPDATE=0
grep -q "RESULT $T/snapshot.pem" <<<"$OUT" && ok "truncated cache not used" || bad "$OUT"

echo "== 'downloaded on' header variant and locale independence"
sed 's/as of:/downloaded on:/' data/new.pem > "$T/variant.pem"
OUT=$(env LC_ALL=de_DE.UTF-8 XDG_CACHE_HOME="$T/cache-M" TEST_SNAPSHOT="$T/variant.pem" WGET_CA_AUTO_UPDATE=0 ./harness 1 2>&1)
grep -q "data as of 2026-03-03" <<<"$OUT" && ok "date parsed" || bad "$OUT"

echo "== network not allowed (--no-check-certificate)"
n=$(reqs); OUT=$(env XDG_CACHE_HOME="$T/cache-N" TEST_SNAPSHOT="$T/snapshot.pem" WGET_CA_UPDATE_URL="https://localhost:$PORT/new" ./harness 0 2>&1)
[ "$(reqs)" = "$n" ] && ok "no request" || bad "$OUT"

echo
echo "passed: $PASS  failed: $FAILS"
[ "$FAILS" -eq 0 ]
