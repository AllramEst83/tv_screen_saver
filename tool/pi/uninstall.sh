#!/usr/bin/env bash
# Remove everything TV Saver put on the Pi. Run on the Pi:
#   sudo bash ~/tvsaver/pi/uninstall.sh --dry-run     (only lists what it would do)
#   sudo bash ~/tvsaver/pi/uninstall.sh
#
# Removes: the tvsaver service and its two timers (Wi-Fi preference, network
# watchdog), the Avahi announcement, /usr/local/lib/tvsaver, the Samba "inbox"
# share and its Samba login, the packages ffmpeg, libvips-tools and samba, and
# ~/tvsaver (server, database, inbox, ALL uploaded photos and videos) plus the
# token in ~/.config/tvsaver. This cannot be undone.
#
# Leaves alone: the Wi-Fi profiles in NetworkManager (removing them could cut
# the Pi off the network), other packages (run `sudo apt autoremove` yourself
# if you want the leftover libraries gone), and everything else on the Pi.

set -u

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: sudo bash uninstall.sh [--dry-run]" >&2; exit 2 ;;
esac

if [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

OWNER="${TVSAVER_OWNER:-allramest}"
HOME_DIR="${TVSAVER_HOME:-/home/$OWNER}"
UNIT_DIR="${TVSAVER_UNIT_DIR:-/etc/systemd/system}"
SMB_CONF="${TVSAVER_SMB_CONF:-/etc/samba/smb.conf}"
AVAHI_FILE="${TVSAVER_AVAHI_FILE:-/etc/avahi/services/tvsaver.service}"
LIB_DIR="${TVSAVER_LIB_DIR:-/usr/local/lib/tvsaver}"

say() { echo "$*"; }
act() { # description, then the command
  local what="$1"; shift
  if [ "$DRY" = 1 ]; then say "[dry-run] would: $what"; else say "$what"; "$@" >/dev/null 2>&1 || true; fi
}

UNITS="tvsaver.service tvsaver-wifi-prefer.timer tvsaver-wifi-prefer.service tvsaver-net-watchdog.timer tvsaver-net-watchdog.service"

# 1. Stop and disable the services first, so nothing recreates the files.
for u in $UNITS; do
  if [ -e "$UNIT_DIR/$u" ]; then
    act "stop and disable $u" systemctl disable --now "$u"
    act "delete $UNIT_DIR/$u" rm -f "$UNIT_DIR/$u"
  fi
done
act "reload systemd" systemctl daemon-reload
act "forget failed units" systemctl reset-failed

# 2. Avahi announcement.
if [ -e "$AVAHI_FILE" ]; then
  act "delete $AVAHI_FILE" rm -f "$AVAHI_FILE"
  act "restart avahi" systemctl restart avahi-daemon
fi

# 3. Helper scripts.
[ -d "$LIB_DIR" ] && act "delete $LIB_DIR" rm -rf "$LIB_DIR"

# 4. The Samba share, its login, then the packages.
if [ -r "$SMB_CONF" ] && grep -q '^# BEGIN tvsaver inbox' "$SMB_CONF"; then
  if [ "$DRY" = 1 ]; then
    say "[dry-run] would: remove the [inbox] share from $SMB_CONF"
  else
    say "remove the [inbox] share from $SMB_CONF"
    sed -i '/^# BEGIN tvsaver inbox$/,/^# END tvsaver inbox$/d' "$SMB_CONF"
  fi
fi
if command -v pdbedit >/dev/null 2>&1; then
  act "remove the Samba login $OWNER" pdbedit -x "$OWNER"
fi
for p in samba ffmpeg libvips-tools; do
  if dpkg -s "$p" >/dev/null 2>&1; then
    act "remove package $p" env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p"
  fi
done

# 5. The data: server, database, inbox, every uploaded file, the token.
[ -d "$HOME_DIR/tvsaver" ] && act "delete $HOME_DIR/tvsaver ($(du -sh "$HOME_DIR/tvsaver" 2>/dev/null | cut -f1): server, database, inbox and all uploaded media)" rm -rf "$HOME_DIR/tvsaver"
[ -d "$HOME_DIR/.config/tvsaver" ] && act "delete $HOME_DIR/.config/tvsaver (the token)" rm -rf "$HOME_DIR/.config/tvsaver"

if [ "$DRY" = 1 ]; then
  say "Nothing was changed (dry run)."
else
  say "Done. TV Saver is gone from this Pi. The Wi-Fi profiles were left as they are."
  say "Optional: sudo apt autoremove   (removes libraries nothing needs any more)"
fi
