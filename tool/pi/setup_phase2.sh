#!/usr/bin/env bash
# Stage spike clips + a 1 GiB sparse file on the Pi and push pi_config.json to
# the TV app's own external files dir (story 2-3). No sudo, no TV settings
# changed, bearer token never printed.
#
#   PI_HOST=192.168.0.43 bash tool/pi/setup_phase2.sh [tv-ip[:port]]

set -eu
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
PI_PORT="${PI_PORT:-8772}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$PI_USER@$PI_HOST"

DEVICE="${1:-192.168.0.24:5555}"
case "$DEVICE" in *:*) ;; *) DEVICE="$DEVICE:5555" ;; esac
PKG="com.codedbykay.tvsaver.tv"
TV_FILES="/sdcard/Android/data/$PKG/files"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build/spike-media"
THROUGHPUT_FILE="throughput-1g.bin"

die() { echo "$*" >&2; exit 1; }

for cmd in adb ssh scp curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found on PATH"
done

shopt -s nullglob
clips=("$SRC"/[1-5]-*.mp4)
[ "${#clips[@]}" -gt 0 ] || die "No clips in $SRC. Run: bash tool/video/generate_clips.sh"

# Verify Pi /health and SSH access.
curl -sf --max-time 5 "http://$PI_HOST:$PI_PORT/health" | grep -q '"ok":true' ||
  die "Pi /health check failed at http://$PI_HOST:$PI_PORT/health (check PI_HOST)"

TOKEN="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'cat ~/.config/tvsaver/token' 2>/dev/null | tr -d '\r\n')"
[ -n "$TOKEN" ] || die "Cannot read ~/.config/tvsaver/token on $TARGET (is tvsaver running?)"

# Stage clips and sparse 1 GiB file in ~/tvsaver/media on the Pi.
echo "== Staging media on $TARGET:~/tvsaver/media =="
ssh "${SSH_OPTS[@]}" "$TARGET" 'mkdir -p ~/tvsaver/media'
for f in "${clips[@]}"; do
  name="$(basename "$f")"
  echo "  scp $name"
  scp -q "${SSH_OPTS[@]}" "$f" "$TARGET:tvsaver/media/$name"
done
ssh "${SSH_OPTS[@]}" "$TARGET" "truncate -s 1G ~/tvsaver/media/$THROUGHPUT_FILE && ls -lh ~/tvsaver/media/"

# Connect to TV and check app installation (read-only).
connect_out="$(adb connect "$DEVICE" 2>&1 | tr -d '\r')"
case "$connect_out" in *"connected to"*) ;; *) die "TV not reachable at $DEVICE ($connect_out)" ;; esac
state="$(adb -s "$DEVICE" get-state 2>&1 | tr -d '\r')"
[ "$state" = "device" ] || die "TV not reachable at $DEVICE (adb state: $state)"

tv() { adb -s "$DEVICE" shell "$@" 2>&1 | tr -d '\r'; }
tv pm path "$PKG" | grep -q package: ||
  die "TV Saver ($PKG) is not installed; install it first (BUILD_AND_DEPLOY.md section 5)."

# Write pi_config.json locally with 0600 permissions, push to TV, then delete.
TMP_CFG="$(mktemp)"
chmod 600 "$TMP_CFG"
trap 'rm -f "$TMP_CFG"' EXIT

playlist_json=""
for f in "${clips[@]}"; do
  name="$(basename "$f")"
  if [ -n "$playlist_json" ]; then playlist_json="$playlist_json, "; fi
  playlist_json="$playlist_json\"$name\""
done

printf '{\n  "host": "%s",\n  "port": %s,\n  "token": "%s",\n  "playlist": [%s],\n  "throughputFile": "%s"\n}\n' \
  "$PI_HOST" "$PI_PORT" "$TOKEN" "$playlist_json" "$THROUGHPUT_FILE" > "$TMP_CFG"

local_cfg="$TMP_CFG"
command -v cygpath >/dev/null 2>&1 && local_cfg="$(cygpath -m "$TMP_CFG")"

tv mkdir -p "$TV_FILES" >/dev/null
adb -s "$DEVICE" push "$local_cfg" "$TV_FILES/pi_config.json" | tr -d '\r' | tail -n 1
[ "${PIPESTATUS[0]}" -eq 0 ] || die "adb push failed for pi_config.json"

echo "Pushed pi_config.json (token redacted) to $TV_FILES/pi_config.json"
echo "Playlist: [$playlist_json]"
echo "Throughput file: $THROUGHPUT_FILE"
