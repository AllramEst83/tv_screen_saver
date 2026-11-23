#!/usr/bin/env bash
# Build the Pi server (linux-arm64 AOT) on the PC and copy it to the Pi
# (scp/ssh only, no sudo). Story 2-2.
#
#   PI_HOST=gemini-pi.local bash tool/pi/deploy_server.sh   (PI_HOST may be an IP)
#
# Copies to ~/tvsaver/bin/tvsaver atomically (tvsaver.new, then mv), also
# copies the install script + units to ~/tvsaver/pi/, then kills the running
# server process (Dart AOT sets comm to "dart:tvsaver", so we match the full
# command path) so systemd (Restart=always) relaunches the new binary. If the
# unit is not installed yet, nothing relaunches it; that is fine.

set -eu
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
PI_PORT="${PI_PORT:-8772}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$PI_USER@$PI_HOST"

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/../../packages/hub_core"
OUT="$PKG/build/tvsaver"

mkdir -p "$PKG/build"
(cd "$PKG" && dart pub get >/dev/null && dart compile exe --target-os linux --target-arch arm64 \
  bin/pi_server.dart -o build/tvsaver)

ssh "${SSH_OPTS[@]}" "$TARGET" 'mkdir -p ~/tvsaver/bin ~/tvsaver/media ~/tvsaver/pi/units' ||
  { echo "cannot reach $TARGET (set PI_HOST to its IP if the name does not resolve)" >&2; exit 1; }

scp -q "${SSH_OPTS[@]}" "$OUT" "$TARGET:tvsaver/bin/tvsaver.new"
scp -q "${SSH_OPTS[@]}" "$HERE/install_server.sh" "$TARGET:tvsaver/pi/"
scp -q "${SSH_OPTS[@]}" "$HERE/units/tvsaver.service" "$HERE/units/tvsaver.avahi.service" "$TARGET:tvsaver/pi/units/"

# Keep the previous binary as tvsaver.prev for rollback, swap atomically, then
# signal any running process so systemd (Restart=always) relaunches the new one.
# Dart AOT sets /proc/<pid>/comm to "dart:tvsaver", so match the full binary path.
RESTART_STATE="$(ssh "${SSH_OPTS[@]}" "$TARGET" '
  set -eu
  if [ -f ~/tvsaver/bin/tvsaver ]; then
    cp -f ~/tvsaver/bin/tvsaver ~/tvsaver/bin/tvsaver.prev
  fi
  chmod +x ~/tvsaver/bin/tvsaver.new ~/tvsaver/pi/install_server.sh
  mv -f ~/tvsaver/bin/tvsaver.new ~/tvsaver/bin/tvsaver
  PAT="^$HOME/tvsaver/bin/tvsaver(\$|[[:space:]])"
  if pkill -f "$PAT" 2>/dev/null; then
    i=0
    while pgrep -f "$PAT" >/dev/null 2>&1 && [ "$i" -lt 30 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    echo RESTARTED
  else
    echo NOT_RUNNING
  fi
' | tr -d '\r\n')"

echo "deployed $TARGET:~/tvsaver/bin/tvsaver"
ssh "${SSH_OPTS[@]}" "$TARGET" 'file ~/tvsaver/bin/tvsaver 2>/dev/null || ls -l ~/tvsaver/bin/tvsaver'

if [ "$RESTART_STATE" = "RESTARTED" ]; then
  ok=0
  for _ in $(seq 1 15); do
    if curl -sf --max-time 2 "http://$PI_HOST:$PI_PORT/health" | grep -q '"ok":true'; then
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" = 1 ]; then
    echo "server restarted and /health is ok on http://$PI_HOST:$PI_PORT/health"
  else
    echo "ERROR: deployed binary did not answer /health within 15 s (rollback: mv -f ~/tvsaver/bin/tvsaver.prev ~/tvsaver/bin/tvsaver && pkill -x dart:tvsaver)" >&2
    exit 1
  fi
else
  echo "note: tvsaver was not running on $TARGET (nothing restarted)"
  echo "next: once, on the Pi: sudo bash ~/tvsaver/pi/install_server.sh --dry-run   (then without --dry-run)"
fi
