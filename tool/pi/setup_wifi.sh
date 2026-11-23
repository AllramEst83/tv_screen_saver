#!/usr/bin/env bash
# Pin the Pi to Wi-Fi Floor 1 with Floor 2 as fallback (story 2-1). Run on the
# Pi:   sudo bash ~/tvsaver/pi/setup_wifi.sh [--dry-run]
#
# Idempotent: a second run reports "no changes". Never prints a PSK.
# Reads /home/allramest/.config/tvsaver/.env (optional) for SSIDs and PSKs.

set -eu
set -o pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: sudo bash setup_wifi.sh [--dry-run]" >&2; exit 2 ;;
esac

if [ "$(id -u)" != 0 ] && [ -z "${TVSAVER_TEST:-}" ]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${TVSAVER_ENV_FILE:-/home/allramest/.config/tvsaver/.env}"
LIB_DIR="${TVSAVER_LIB_DIR:-/usr/local/lib/tvsaver}"
UNIT_DIR="${TVSAVER_UNIT_DIR:-/etc/systemd/system}"
MIN_SIGNAL=40
CHANGES=0

say() { echo "$*"; }
planned() { CHANGES=$((CHANGES + 1)); if [ "$DRY" = 1 ]; then say "[dry-run] would: $*"; else say "$*"; fi; }

envget() {
  [ -r "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n1 |
    sed -e 's/\r$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

getp() { nmcli -g "$2" connection show "$1" 2>/dev/null || true; }

want() { # profile property value
  local cur
  cur="$(getp "$1" "$2")"
  [ "$cur" = "$3" ] && return 0
  planned "$1: $2 '$cur' -> '$3'"
  [ "$DRY" = 1 ] || nmcli connection modify "$1" "$2" "$3"
}

set_psk() { # profile psk  (PSK goes over stdin, never argv)
  local cur
  [ -n "$2" ] || return 0
  cur="$(nmcli -s -g 802-11-wireless-security.psk connection show "$1" 2>/dev/null || true)"
  [ "$cur" = "$2" ] && return 0
  planned "$1: update saved PSK (value not shown)"
  [ "$DRY" = 1 ] || printf 'set wifi-sec.psk %s\nsave\nquit\n' "$2" | nmcli connection edit "$1" >/dev/null
}

install_file() { # src dst mode
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 1; fi
  planned "install $2"
  if [ "$DRY" != 1 ]; then
    if ! { mkdir -p "$(dirname "$2")" && install -m "$3" "$1" "$2"; }; then
      echo "install failed: $2 (aborting before the timer is enabled)" >&2
      exit 1
    fi
  fi
  return 0
}

F1="$(envget WIFI_FLOOR1_SSID)"; F1="${F1:-LightSpeed_Auto_Floor_1}"
F2="$(envget WIFI_FLOOR2_SSID)"; F2="${F2:-LightSpeed_Auto_Floor_2}"
PSK1="$(envget WIFI_FLOOR1_PSK)"
PSK2="$(envget WIFI_FLOOR2_PSK)"

# ---- preflight: no changes unless everything needed exists ----
profiles="$(nmcli -t -f NAME,TYPE connection show)"
wifi_profiles="$(printf '%s\n' "$profiles" | awk -F: '$2=="802-11-wireless"{print $1}')"
has_profile() { printf '%s\n' "$wifi_profiles" | grep -Fxq "$1"; }

if ! has_profile "$F1"; then
  echo "Wi-Fi profile not found: $F1 (nothing changed)" >&2
  exit 1
fi
HAVE_F2=1
if ! has_profile "$F2"; then
  HAVE_F2=0
  echo "warning: Wi-Fi profile not found: $F2 (no fallback to configure)"
fi
for f in wifi_prefer.sh units/tvsaver-wifi-prefer.service units/tvsaver-wifi-prefer.timer; do
  [ -f "$HERE/$f" ] || { echo "missing file next to the script: $f (nothing changed)" >&2; exit 1; }
done

if [ -r "$ENV_FILE" ]; then
  say "env: $ENV_FILE found"
else
  say "env: $ENV_FILE missing, saved PSKs left untouched"
fi

# ---- 5 GHz lock only when a strong 5 GHz BSS of Floor 1 is visible ----
say "scanning for $F1 ..."
scan="$(nmcli -t -f SSID,FREQ,SIGNAL dev wifi list --rescan yes 2>/dev/null || true)"
eligible="$(printf '%s\n' "$scan" |
  awk -F: -v s="$F1" -v m="$MIN_SIGNAL" '$1==s && ($2+0)>=5000 && ($3+0)>=m {print "yes"; exit}')"

# ---- profile settings ----
want "$F1" connection.autoconnect yes
want "$F1" connection.autoconnect-priority 100
want "$F1" connection.autoconnect-retries 0
if [ "$eligible" = yes ]; then
  want "$F1" 802-11-wireless.band a
else
  say "warning: no 5 GHz BSS of $F1 with signal >= $MIN_SIGNAL visible; band lock not set (any existing lock is cleared)"
  want "$F1" 802-11-wireless.band ""
fi
set_psk "$F1" "$PSK1"

if [ "$HAVE_F2" = 1 ]; then
  want "$F2" connection.autoconnect yes
  want "$F2" connection.autoconnect-priority 10
  want "$F2" connection.autoconnect-retries 0
  set_psk "$F2" "$PSK2"
fi

while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ "$p" = "$F1" ] && continue
  [ "$p" = "$F2" ] && continue
  want "$p" connection.autoconnect no
done <<< "$wifi_profiles"

# ---- timer ----
reload=0
install_file "$HERE/wifi_prefer.sh" "$LIB_DIR/wifi_prefer.sh" 755 && reload=1
install_file "$HERE/units/tvsaver-wifi-prefer.service" "$UNIT_DIR/tvsaver-wifi-prefer.service" 644 && reload=1
install_file "$HERE/units/tvsaver-wifi-prefer.timer" "$UNIT_DIR/tvsaver-wifi-prefer.timer" 644 && reload=1
if [ "$DRY" != 1 ]; then
  [ "$reload" = 0 ] || systemctl daemon-reload
  if ! systemctl is-enabled --quiet tvsaver-wifi-prefer.timer 2>/dev/null ||
     ! systemctl is-active --quiet tvsaver-wifi-prefer.timer 2>/dev/null; then
    planned "enable and start tvsaver-wifi-prefer.timer"
    systemctl enable --now tvsaver-wifi-prefer.timer >/dev/null 2>&1
  elif [ "$reload" = 1 ]; then
    planned "restart tvsaver-wifi-prefer.timer"
    systemctl restart tvsaver-wifi-prefer.timer
  fi
else
  if ! systemctl is-enabled --quiet tvsaver-wifi-prefer.timer 2>/dev/null ||
     ! systemctl is-active --quiet tvsaver-wifi-prefer.timer 2>/dev/null; then
    planned "enable and start tvsaver-wifi-prefer.timer"
  fi
fi

if [ "$CHANGES" = 0 ]; then
  say "no changes"
elif [ "$DRY" = 1 ]; then
  say "dry run: $CHANGES change(s) planned, nothing applied"
else
  say "done: $CHANGES change(s) applied"
fi
