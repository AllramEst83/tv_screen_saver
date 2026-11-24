#!/usr/bin/env bash
# Pi Wi-Fi self-heal (run once on the Pi as root):
#   sudo bash ~/tvsaver/pi/install_net_watchdog.sh [--dry-run]
#
# Installs tvsaver-net-watchdog.timer (every 30 s). It pings the default
# gateway; after consecutive failures it escalates:
#    3 fails (~1.5 min)  nmcli reconnect of the active Wi-Fi profile
#    6 fails (~3 min)    restart NetworkManager
#   10 fails (~5 min)    reload the brcmfmac Wi-Fi driver
#   20 fails (~10 min)   reboot (only if the Pi has been up > 15 min)
# Every action is logged to the journal (journalctl -t tvsaver-net-watchdog).
# Idempotent. Writes only the three files below.

set -eu

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

if [ "$DRY" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo bash $0 [--dry-run]" >&2
  exit 1
fi

BIN=/usr/local/lib/tvsaver/net_watchdog.sh
SVC=/etc/systemd/system/tvsaver-net-watchdog.service
TMR=/etc/systemd/system/tvsaver-net-watchdog.timer

WATCHDOG='#!/usr/bin/env bash
set -u
TAG=tvsaver-net-watchdog
STATE=/run/tvsaver-net-watchdog.fails
log() { logger -t "$TAG" "$*"; }

GW="$(ip route show default 2>/dev/null | awk "NR==1{print \$3}")"
if [ -n "$GW" ] && ping -c 2 -W 2 "$GW" >/dev/null 2>&1; then
  if [ -f "$STATE" ]; then
    log "gateway $GW reachable again after $(cat "$STATE") failed checks"
    rm -f "$STATE"
  fi
  exit 0
fi

n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STATE"
log "gateway ${GW:-none} unreachable (failure $n)"

case "$n" in
  3)
    PROFILE="$(nmcli -t -f NAME,TYPE connection show --active | awk -F: "\$2==\"802-11-wireless\"{print \$1; exit}")"
    [ -n "$PROFILE" ] || PROFILE=LightSpeed_Auto_Floor_1
    log "step 1: reconnecting Wi-Fi profile $PROFILE"
    nmcli connection up "$PROFILE" || log "step 1 failed"
    ;;
  6)
    log "step 2: restarting NetworkManager"
    systemctl restart NetworkManager || log "step 2 failed"
    ;;
  10)
    log "step 3: reloading brcmfmac driver"
    modprobe -r brcmfmac_wcc brcmfmac 2>/dev/null || modprobe -r brcmfmac 2>/dev/null || true
    sleep 2
    modprobe brcmfmac || log "step 3 failed"
    sleep 5
    systemctl restart NetworkManager || true
    ;;
  20)
    up="$(cut -d. -f1 /proc/uptime)"
    if [ "$up" -gt 900 ]; then
      log "step 4: rebooting (uptime ${up}s)"
      systemctl reboot
    else
      log "step 4 skipped: uptime ${up}s < 900s (avoiding a reboot loop)"
    fi
    ;;
esac
exit 0'

SERVICE='[Unit]
Description=TV Saver Pi network watchdog (Wi-Fi self-heal)

[Service]
Type=oneshot
ExecStart=/usr/local/lib/tvsaver/net_watchdog.sh'

TIMER='[Unit]
Description=Run the TV Saver Pi network watchdog every 30 s

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target'

changed=0
want_file() { # path, content, mode
  local path="$1" content="$2" mode="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    echo "ok      $path (unchanged)"
    return 0
  fi
  changed=1
  if [ "$DRY" = 1 ]; then
    echo "would write $path"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  chmod "$mode" "$path"
  echo "wrote   $path"
}

want_file "$BIN" "$WATCHDOG" 755
want_file "$SVC" "$SERVICE" 644
want_file "$TMR" "$TIMER" 644

if [ "$DRY" = 1 ]; then
  echo "would run: systemctl daemon-reload; systemctl enable --now tvsaver-net-watchdog.timer"
  exit 0
fi

systemctl daemon-reload
systemctl enable --now tvsaver-net-watchdog.timer
echo "timer active: $(systemctl is-active tvsaver-net-watchdog.timer)"
echo "Logs: journalctl -t tvsaver-net-watchdog -n 20"
