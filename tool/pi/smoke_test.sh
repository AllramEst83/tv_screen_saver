#!/usr/bin/env bash
# Smoke test of the real Pi server from the PC (story 2-2). The server must be
# running (systemd, or started by hand on the Pi).
#
#   PI_HOST=192.168.0.43 bash tool/pi/smoke_test.sh
#
# Reads the bearer token over ssh and hands it to curl on stdin (never argv,
# never printed). Creates temporary files named smoke-* in ~/tvsaver/media on
# the Pi (a 1 GiB sparse file plus a small one) and removes them on exit.

set -u
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"
PORT="${PI_PORT:-8772}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$PI_USER@$PI_HOST"
BASE="http://$PI_HOST:$PORT"

FAILS=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
check() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

rssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# health, no token (abort early if the server is not reachable)
body="$(curl -s --max-time 5 -w '\n%{http_code}' "$BASE/health")"
health_code="$(echo "$body" | tail -n1)"
check "/health 200 without token" 200 "$health_code"
if [ "$health_code" != "200" ]; then
  echo "aborting: $BASE/health did not answer 200 (is tvsaver running?)" >&2
  exit 1
fi
echo "$body" | head -n1 | grep -q '"ok":true' && ok "/health body has ok:true" || bad "/health body"

# token file permissions and read
MODE="$(rssh 'stat -c %a ~/.config/tvsaver/token' 2>/dev/null | tr -d '\r\n')"
check "token file mode is 600" 600 "$MODE"
TOKEN="$(rssh 'cat ~/.config/tvsaver/token' 2>/dev/null | tr -d '\r\n')"
[ -n "$TOKEN" ] || { echo "cannot read the token on $TARGET (is the server run once?)" >&2; exit 1; }

# curl with the token passed through a stdin config (not argv).
acurl() { printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -K - "$@"; }

TMP_RANGE="$(mktemp)"
if command -v cygpath >/dev/null 2>&1; then
  CURL_TMP_RANGE="$(cygpath -m "$TMP_RANGE")"
else
  CURL_TMP_RANGE="$TMP_RANGE"
fi

cleanup() {
  rm -f "$TMP_RANGE"
  rssh 'rm -f ~/tvsaver/media/smoke-small.bin ~/tvsaver/media/smoke-1g.bin' >/dev/null 2>&1
}
trap cleanup EXIT

rssh 'mkdir -p ~/tvsaver/media && head -c 4096 /dev/urandom > ~/tvsaver/media/smoke-small.bin && truncate -s 1G ~/tvsaver/media/smoke-1g.bin' ||
  { echo "cannot create test files on the Pi" >&2; exit 1; }
SIZE=4096

# 401
check "no token -> 401" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/media/smoke-small.bin/full")"
check "wrong token -> 401" 401 "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "$BASE/media/smoke-small.bin/full")"

# full
check "GET full -> 200" 200 "$(acurl -o /dev/null -w '%{http_code}' "$BASE/media/smoke-small.bin/full")"

# range from the middle: status, Content-Range and bytes
hdr="$(acurl -D - -o "$CURL_TMP_RANGE" -H 'Range: bytes=100-199' "$BASE/media/smoke-small.bin/full" | tr -d '\r')"
check "Range 100-199 -> 206" 206 "$(echo "$hdr" | head -n1 | awk '{print $2}')"
check "Content-Range" "bytes 100-199/$SIZE" "$(echo "$hdr" | awk -F': ' 'tolower($1)=="content-range"{print $2}')"
want="$(rssh 'dd if=~/tvsaver/media/smoke-small.bin bs=1 skip=100 count=100 2>/dev/null | sha256sum' | awk '{print $1}')"
got="$(sha256sum < "$TMP_RANGE" | awk '{print $1}')"
check "Range body bytes match" "$want" "$got"

# suffix, open-ended
check "suffix bytes=-100 Content-Range" "bytes $((SIZE - 100))-$((SIZE - 1))/$SIZE" \
  "$(acurl -D - -o /dev/null -H 'Range: bytes=-100' "$BASE/media/smoke-small.bin/full" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-range"{print $2}')"
check "open-ended bytes=4000- Content-Range" "bytes 4000-$((SIZE - 1))/$SIZE" \
  "$(acurl -D - -o /dev/null -H 'Range: bytes=4000-' "$BASE/media/smoke-small.bin/full" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-range"{print $2}')"

# 416
hdr="$(acurl -D - -o /dev/null -H "Range: bytes=$SIZE-" "$BASE/media/smoke-small.bin/full" | tr -d '\r')"
check "Range past end -> 416" 416 "$(echo "$hdr" | head -n1 | awk '{print $2}')"
check "416 Content-Range" "bytes */$SIZE" "$(echo "$hdr" | awk -F': ' 'tolower($1)=="content-range"{print $2}')"

# HEAD
hdr="$(acurl -I "$BASE/media/smoke-small.bin/full" | tr -d '\r')"
check "HEAD -> 200" 200 "$(echo "$hdr" | head -n1 | awk '{print $2}')"
check "HEAD Content-Length" "$SIZE" "$(echo "$hdr" | awk -F': ' 'tolower($1)=="content-length"{print $2}')"

# traversal / bad ids (--path-as-is keeps the dot segments on the wire)
for p in '/media/../etc/passwd/full' '/media/%2e%2e/full' '/media/a%2Fb/full' '/media/..%2F..%2Fetc%2Fpasswd/full'; do
  code="$(acurl -o /dev/null -w '%{http_code}' --path-as-is "$BASE$p")"
  case "$code" in 400|404) ok "traversal $p -> $code" ;; *) bad "traversal $p -> $code" ;; esac
done
check "unknown id -> 404" 404 "$(acurl -o /dev/null -w '%{http_code}' "$BASE/media/nope/full")"

# 1 GiB file: a 206 read from the middle in under 3 s
t="$(acurl -o /dev/null -w '%{http_code} %{time_total}' -H 'Range: bytes=536870912-537395199' "$BASE/media/smoke-1g.bin/full")"
code="${t%% *}"; secs="${t##* }"
check "1 GiB middle Range -> 206" 206 "$code"
if awk -v s="$secs" 'BEGIN{exit !(s < 3)}'; then ok "1 GiB middle Range in ${secs}s (< 3 s)"; else bad "1 GiB middle Range took ${secs}s"; fi

echo
if [ "$FAILS" = 0 ]; then echo "all checks passed"; else echo "$FAILS check(s) failed"; exit 1; fi
