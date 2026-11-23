#!/usr/bin/env bash
# Install the tvsaver systemd unit and the Avahi _tvsaver._tcp service (story
# 2-2). Run once on the Pi:   sudo bash ~/tvsaver/pi/install_server.sh [--dry-run]
#
# Idempotent: a second run reports "no changes". Needs ~/tvsaver/bin/tvsaver
# (deploy_server.sh from the PC puts it there).

set -eu
set -o pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: sudo bash install_server.sh [--dry-run]" >&2; exit 2 ;;
esac

if [ "$(id -u)" != 0 ] && [ -z "${TVSAVER_TEST:-}" ]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
UNIT_DIR="${TVSAVER_UNIT_DIR:-/etc/systemd/system}"
AVAHI_DIR="${TVSAVER_AVAHI_DIR:-/etc/avahi/services}"
BIN="${TVSAVER_BIN:-/home/allramest/tvsaver/bin/tvsaver}"
CHANGES=0

say() { echo "$*"; }
planned() { CHANGES=$((CHANGES + 1)); if [ "$DRY" = 1 ]; then say "[dry-run] would: $*"; else say "$*"; fi; }

for f in units/tvsaver.service units/tvsaver.avahi.service; do
  [ -f "$HERE/$f" ] || { echo "missing file next to the script: $f (nothing changed)" >&2; exit 1; }
done
if [ ! -x "$BIN" ]; then
  echo "warning: $BIN not found or not executable; run deploy_server.sh from the PC first (the service will fail until then)"
fi

install_file() { # src dst
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  planned "install $2"
  if [ "$DRY" != 1 ]; then
    mkdir -p "$(dirname "$2")" && install -m 644 "$1" "$2" || { echo "install failed: $2" >&2; exit 1; }
  fi
  return 0
}

reload=0
if install_file "$HERE/units/tvsaver.service" "$UNIT_DIR/tvsaver.service"; then
  reload=1
fi
avahi_changed=0
if install_file "$HERE/units/tvsaver.avahi.service" "$AVAHI_DIR/tvsaver.service"; then
  avahi_changed=1
fi

if [ "$reload" = 1 ]; then
  planned "systemctl daemon-reload"
  if [ "$DRY" != 1 ]; then
    systemctl daemon-reload || { echo "systemctl daemon-reload failed" >&2; exit 1; }
  fi
fi

if ! systemctl is-enabled --quiet tvsaver.service 2>/dev/null ||
   ! systemctl is-active --quiet tvsaver.service 2>/dev/null; then
  planned "enable and start tvsaver.service"
  if [ "$DRY" != 1 ]; then
    systemctl enable --now tvsaver.service >/dev/null || {
      echo "failed to enable/start tvsaver.service (check: journalctl -u tvsaver -n 20)" >&2
      exit 1
    }
  fi
elif [ "$reload" = 1 ]; then
  planned "restart tvsaver.service"
  if [ "$DRY" != 1 ]; then
    systemctl restart tvsaver.service || {
      echo "failed to restart tvsaver.service (check: journalctl -u tvsaver -n 20)" >&2
      exit 1
    }
  fi
fi

if ! systemctl is-enabled --quiet avahi-daemon.service 2>/dev/null ||
   ! systemctl is-active --quiet avahi-daemon.service 2>/dev/null; then
  planned "enable and start avahi-daemon.service"
  if [ "$DRY" != 1 ]; then
    systemctl enable --now avahi-daemon.service >/dev/null || {
      echo "failed to enable/start avahi-daemon.service" >&2
      exit 1
    }
  fi
elif [ "$avahi_changed" = 1 ]; then
  planned "reload avahi-daemon.service"
  if [ "$DRY" != 1 ]; then
    systemctl reload avahi-daemon.service 2>/dev/null || systemctl restart avahi-daemon.service || {
      echo "failed to reload/restart avahi-daemon.service" >&2
      exit 1
    }
  fi
fi

if [ "$CHANGES" = 0 ]; then
  say "no changes"
elif [ "$DRY" = 1 ]; then
  say "dry run: $CHANGES change(s) planned, nothing applied"
else
  say "done: $CHANGES change(s) applied"
  say "check: systemctl status tvsaver; avahi-browse -rt _tvsaver._tcp"
fi
