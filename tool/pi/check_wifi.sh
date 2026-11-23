#!/usr/bin/env bash
# Read-only Wi-Fi status of the Pi: active profile, band, signal, IP, timer
# state, last journal lines. Never queries or prints secrets.
#
#   PI_HOST=gemini-pi.local tool/pi/check_wifi.sh
# Exit: 0 state printed, 1 Pi not reachable.

set -u
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"

# shellcheck disable=SC2016
REMOTE='
echo "== active connections"; nmcli -t -f NAME,TYPE,DEVICE connection show --active
echo "== Wi-Fi in use (cached scan; * = connected: SSID:freq:signal)"
nmcli -t -f IN-USE,SSID,FREQ,SIGNAL dev wifi list 2>/dev/null | grep "^\*"
echo "== Floor profiles (priority / band)"
nmcli -t -f NAME,TYPE connection show | awk -F: "\$2==\"802-11-wireless\"{print \$1}" | while IFS= read -r p; do
  echo "$p: priority=$(nmcli -g connection.autoconnect-priority connection show "$p") autoconnect=$(nmcli -g connection.autoconnect connection show "$p") band=$(nmcli -g 802-11-wireless.band connection show "$p")"
done
echo "== IPv4"; ip -4 -br addr show scope global
echo "== timer"; echo "enabled=$(systemctl is-enabled tvsaver-wifi-prefer.timer 2>&1) active=$(systemctl is-active tvsaver-wifi-prefer.timer 2>&1)"
echo "== last journal lines"; journalctl -u tvsaver-wifi-prefer.service -n 5 --no-pager 2>&1 | tail -n 6
exit 0
'

ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 "$PI_USER@$PI_HOST" "$REMOTE" ||
  { echo "cannot reach $PI_USER@$PI_HOST (set PI_HOST to its IP if the name does not resolve)" >&2; exit 1; }
