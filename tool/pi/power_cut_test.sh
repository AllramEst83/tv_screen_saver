#!/usr/bin/env bash
# Interactive power-cut recovery test for the Pi (story 2-3, CAP-11).
# Verifies Floor 1 baseline + /health, prompts Kay to pull & restore Pi power,
# times /health recovery (pass <= 120 s), and checks Floor 1 Wi-Fi, tvsaver
# service active, and Avahi _tvsaver._tcp advertisement. No sudo, no secrets.
#
#   PI_HOST=192.168.0.43 bash tool/pi/power_cut_test.sh

set -u
export MSYS_NO_PATHCONV=1

PI_HOST="${PI_HOST:-gemini-pi.local}"
PI_USER="${PI_USER:-allramest}"
PI_PORT="${PI_PORT:-8772}"
KEY="${PI_KEY:-$HOME/.ssh/id_ed25519_claude}"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8)
TARGET="$PI_USER@$PI_HOST"
BASE="http://$PI_HOST:$PI_PORT"
TIMEOUT_S="${TIMEOUT_S:-120}"
FLOOR1_SSID="${FLOOR1_SSID:-LightSpeed_Auto_Floor_1}"

FAILS=0
ok() { echo "PASS - $1"; }
fail() { echo "FAIL - $1" >&2; FAILS=$((FAILS + 1)); }
rssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@" 2>/dev/null; }

check_pi_state() {
  local phase="$1"
  local active_wifi svc avahi

  active_wifi="$(rssh "nmcli -t -f NAME,TYPE connection show --active | awk -F: '\$2==\"802-11-wireless\"{print \$1; exit}'" | tr -d '\r\n')"
  if [ "$active_wifi" = "$FLOOR1_SSID" ]; then
    local details
    details="$(rssh "nmcli -t -f IN-USE,SSID,FREQ,SIGNAL dev wifi list | grep '^\*'" | tr -d '\r\n')"
    ok "$phase: Wi-Fi is $FLOOR1_SSID ($details)"
  elif [ -n "$active_wifi" ]; then
    fail "$phase: Pi is on '$active_wifi' instead of '$FLOOR1_SSID'"
  else
    fail "$phase: could not read active Wi-Fi profile over SSH"
  fi

  svc="$(rssh 'systemctl is-active tvsaver' | tr -d '\r\n')"
  if [ "$svc" = "active" ]; then
    ok "$phase: tvsaver.service is active"
  else
    fail "$phase: tvsaver.service state is '$svc' (expected active)"
  fi

  avahi="$(rssh 'avahi-browse -rt _tvsaver._tcp' | tr -d '\r')"
  if echo "$avahi" | grep -q "_tvsaver._tcp" && echo "$avahi" | grep -q "$PI_PORT"; then
    ok "$phase: Avahi lists _tvsaver._tcp on port $PI_PORT"
  else
    fail "$phase: Avahi _tvsaver._tcp on port $PI_PORT missing"
  fi
}

echo "== Step 0: Baseline check on $PI_HOST =="
if curl -sf --max-time 5 "$BASE/health" | grep -q '"ok":true'; then
  ok "baseline: $BASE/health returned 200 ok:true"
else
  fail "baseline: $BASE/health unreachable"
  exit 1
fi

check_pi_state "baseline"
if [ "$FAILS" -gt 0 ]; then
  echo "Baseline failed; fix before running the power-cut test." >&2
  exit 1
fi

echo
echo "== Step 1: Pull Pi power =="
printf 'Start playback on the TV, pull the Pi power cable, confirm TV shows "Reconnecting…", then press Enter...'
read -r _

if curl -sf --max-time 2 "$BASE/health" >/dev/null 2>&1; then
  echo "Note: $BASE/health still answered; waiting up to 15 s for it to drop..."
  dropped=0
  for _ in $(seq 1 15); do
    if ! curl -sf --max-time 1 "$BASE/health" >/dev/null 2>&1; then
      dropped=1
      break
    fi
    sleep 1
  done
  if [ "$dropped" = 1 ]; then
    ok "power cut confirmed: /health unreachable"
  else
    fail "/health is still reachable — was power pulled?"
    exit 1
  fi
else
  ok "power cut confirmed: /health unreachable"
fi

echo
echo "== Step 2: Restore Pi power =="
printf 'Restore Pi power now and press Enter IMMEDIATELY to start the %ss timer...' "$TIMEOUT_S"
read -r _
start_ts="$(date +%s)"

recovered=0
elapsed=0
while :; do
  now_ts="$(date +%s)"
  elapsed=$((now_ts - start_ts))
  if curl -sf --max-time 2 "$BASE/health" 2>/dev/null | grep -q '"ok":true'; then
    recovered=1
    break
  fi
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    break
  fi
  sleep 2
done

if [ "$recovered" = 1 ]; then
  ok "/health answered 200 in ${elapsed}s (<= ${TIMEOUT_S}s)"
else
  fail "/health did not recover within ${TIMEOUT_S}s"
  exit 1
fi

# Give sshd a brief moment if /health came up right as networking stabilized.
ssh_ok=0
for _ in $(seq 1 8); do
  if rssh 'true'; then
    ssh_ok=1
    break
  fi
  sleep 2
done
if [ "$ssh_ok" != 1 ]; then
  fail "SSH to $TARGET unavailable after /health recovery"
  exit 1
fi

echo
echo "== Step 3: Post-recovery checks =="
check_pi_state "post-recovery"

echo
if [ "$FAILS" = 0 ]; then
  echo "POWER-CUT TEST PASSED (${elapsed}s recovery)."
  echo "Also verify TV auto-resumed and check: adb logcat -d -s flutter | grep PiStream"
  exit 0
else
  echo "POWER-CUT TEST FAILED ($FAILS check(s) failed)." >&2
  exit 1
fi
