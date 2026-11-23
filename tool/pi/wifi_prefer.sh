#!/usr/bin/env bash
# Timer action: if the active Wi-Fi profile is Floor 2 and Floor 1 is visible,
# switch back to Floor 1. Quiet when Floor 1 (or anything else) is active.
# Installed to /usr/local/lib/tvsaver/ by setup_wifi.sh and run as root by
# tvsaver-wifi-prefer.service. One log line per decision (stdout -> journal).
# If `con up` fails, NetworkManager falls back to Floor 2 on its own.

set -u

ENV_FILE="${TVSAVER_ENV_FILE:-/home/allramest/.config/tvsaver/.env}"
LOCK_FILE="${TVSAVER_LOCK_FILE:-/run/tvsaver-wifi-prefer.lock}"

envget() {
  [ -r "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n1 |
    sed -e 's/\r$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

F1="$(envget WIFI_FLOOR1_SSID)"; F1="${F1:-LightSpeed_Auto_Floor_1}"
F2="$(envget WIFI_FLOOR2_SSID)"; F2="${F2:-LightSpeed_Auto_Floor_2}"

log() { echo "wifi-prefer: $*"; }

STAMP_FILE="${TVSAVER_STAMP_FILE:-$(dirname "$LOCK_FILE")/tvsaver-wifi-prefer.failed}"
MIN_SIGNAL=40
BACKOFF=600

exec 9>"$LOCK_FILE" || exit 0
flock -n 9 || exit 0

active="$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null |
  awk -F: '$2=="802-11-wireless"{print $1; exit}')"

# Act only on Floor 2, or when no Wi-Fi is active at all (offline recovery).
if [ -n "$active" ] && [ "$active" != "$F2" ]; then exit 0; fi
from="${active:-no Wi-Fi}"

if [ -r "$STAMP_FILE" ]; then
  failed_at="$(cat "$STAMP_FILE" 2>/dev/null)"
  now="$(date +%s)"
  case "$failed_at" in ''|*[!0-9]*) failed_at=0 ;; esac
  if [ $((now - failed_at)) -lt "$BACKOFF" ]; then
    log "on $from: backing off after a failed switch to $F1"
    exit 0
  fi
fi

band="$(nmcli -g 802-11-wireless.band connection show "$F1" 2>/dev/null || true)"
scan="$(nmcli -t -f SSID,FREQ,SIGNAL dev wifi list --rescan yes 2>/dev/null || true)"
eligible="$(printf '%s
' "$scan" | awk -F: -v s="$F1" -v m="$MIN_SIGNAL" -v b="$band"   '$1==s && ($3+0)>=m && (b!="a" || ($2+0)>=5000) {print "yes"; exit}')"

if [ "$eligible" != yes ]; then
  log "on $from, $F1 not visible or not eligible (signal >= $MIN_SIGNAL${band:+, band $band}): staying"
  exit 0
fi

if nmcli connection up "$F1" >/dev/null 2>&1; then
  rm -f "$STAMP_FILE"
  log "on $from, $F1 visible: switched to $F1"
else
  date +%s > "$STAMP_FILE"
  log "on $from, $F1 visible: 'connection up' failed, staying (no retry for ${BACKOFF}s)"
fi
exit 0
