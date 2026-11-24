#!/usr/bin/env bash
# Pi stability hardening (run once on the Pi as root):
#   sudo bash ~/tvsaver/pi/harden_pi.sh [--dry-run]
# 1. Persistent systemd journal, so the log of a crashed/unreachable boot survives.
# 2. Wi-Fi power-save off for all NetworkManager Wi-Fi connections (takes effect
#    at the next reboot or Wi-Fi reconnect; the current SSH session is not cut).
# Idempotent. Changes nothing outside these two files.

set -eu

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [--dry-run]" >&2
  exit 1
fi

JOURNAL_CONF=/etc/systemd/journald.conf.d/tvsaver-persistent.conf
NM_CONF=/etc/NetworkManager/conf.d/tvsaver-wifi-powersave.conf

want_file() { # path, content
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    echo "ok      $path (unchanged)"
    return 1
  fi
  if [ "$DRY" = 1 ]; then
    echo "would write $path"
    return 1
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  echo "wrote   $path"
  return 0
}

if want_file "$JOURNAL_CONF" "[Journal]
Storage=persistent
SystemMaxUse=200M"; then
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal || true
  systemctl restart systemd-journald
  echo "restarted systemd-journald"
fi

if want_file "$NM_CONF" "[connection]
wifi.powersave = 2"; then
  systemctl reload NetworkManager || true
  echo "reloaded NetworkManager (power-save off applies at next reconnect/reboot)"
fi

echo
echo "Check after the next reboot:"
echo "  journalctl --list-boots        (should list more than one boot)"
echo "  cat /sys/class/net/wlan0/device/power/control 2>/dev/null; nmcli -g 802-11-wireless.powersave con show LightSpeed_Auto_Floor_1"
