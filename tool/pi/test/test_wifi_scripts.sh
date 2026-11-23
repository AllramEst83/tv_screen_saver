#!/usr/bin/env bash
# Regression tests for setup_wifi.sh and wifi_prefer.sh using a fake nmcli,
# systemctl and flock on PATH. No Pi, no root, no network.
#   bash tool/pi/test/test_wifi_scripts.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PI="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
SECRET="s3cr3t-PSK-value-12345"

FAILS=0; PASSES=0
check() { # name, command...
  local n="$1"; shift
  if "$@"; then PASSES=$((PASSES + 1)); echo "ok   $n"; else FAILS=$((FAILS + 1)); echo "FAIL $n"; fi
}
has() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" "${3:-/dev/stdin}" <<<"$1" 2>/dev/null; }
nothas() { ! grep -Fq -- "$2" <<<"$1"; }
nofile_has() { ! grep -Eq -- "$2" "$1"; }

mkdir -p "$T/bin"
cat > "$T/bin/nmcli" <<'FAKE'
#!/usr/bin/env bash
# Fake nmcli backed by files in $FAKE_STATE.
S="$FAKE_STATE"
echo "nmcli $*" >> "$S/calls.log"
G=""; SHOW=0; FIELDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) shift ;;
    -s) SHOW=1; shift ;;
    -g) G="$2"; shift 2 ;;
    -f) FIELDS="$2"; shift 2 ;;
    *) break ;;
  esac
done
prop() { # profile prop
  local f="$S/prof/$1/$2"
  if [ -f "$f" ]; then cat "$f"; else
    case "$2" in
      connection.autoconnect) echo yes ;;
      connection.autoconnect-priority) echo 0 ;;
      connection.autoconnect-retries) echo -1 ;;
      *) echo "" ;;
    esac
  fi
}
case "$1 ${2:-}" in
  "connection show")
    if [ -n "$G" ]; then
      [ -d "$S/prof/$3" ] || exit 10
      if [ "$G" = 802-11-wireless-security.psk ] && [ "$SHOW" = 0 ]; then echo "<hidden>"; exit 0; fi
      prop "$3" "$G"
    elif [ "${3:-}" = "--active" ]; then
      [ -s "$S/active" ] && echo "$(cat "$S/active"):802-11-wireless:wlan0"
    else
      for d in "$S"/prof/*/; do n="$(basename "$d")"; echo "$n:$(cat "$d/type")"; done
    fi ;;
  "connection modify")
    n="$3"; shift 3
    while [ $# -gt 1 ]; do echo "$2" > "$S/prof/$n/$1"; shift 2; done ;;
  "connection edit")
    n="$3"
    while IFS= read -r line; do
      case "$line" in "set wifi-sec.psk "*) echo "${line#set wifi-sec.psk }" > "$S/prof/$n/802-11-wireless-security.psk" ;; esac
    done ;;
  "connection up")
    echo "$3" >> "$S/up.log"
    [ -f "$S/up_fail" ] && exit 4
    echo "$3" > "$S/active" ;;
  "dev wifi") if [ "$FIELDS" = SSID ]; then cut -d: -f1 "$S/scan"; else cat "$S/scan"; fi ;;
  *) echo "fake nmcli: unhandled $*" >&2; exit 99 ;;
esac
FAKE
cat > "$T/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_STATE/calls.log"
case "$1" in
  is-enabled|is-active) [ -f "$FAKE_STATE/timer_on" ] ;;
  enable) touch "$FAKE_STATE/timer_on" ;;
esac
FAKE
cat > "$T/bin/flock" <<'FAKE'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/lock_busy" ] && exit 1
exit 0
FAKE
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export TVSAVER_TEST=1

F1=LightSpeed_Auto_Floor_1; F2=LightSpeed_Auto_Floor_2

new_state() { # sets FAKE_STATE, fresh profiles
  export FAKE_STATE="$T/state.$RANDOM$RANDOM"
  mkdir -p "$FAKE_STATE/prof/$F1" "$FAKE_STATE/prof/$F2" "$FAKE_STATE/prof/Wired connection 1" "$FAKE_STATE/prof/OtherWifi"
  echo 802-11-wireless > "$FAKE_STATE/prof/$F1/type"
  echo 802-11-wireless > "$FAKE_STATE/prof/$F2/type"
  echo 802-11-wireless > "$FAKE_STATE/prof/OtherWifi/type"
  echo 802-3-ethernet > "$FAKE_STATE/prof/Wired connection 1/type"
  echo -999 > "$FAKE_STATE/prof/Wired connection 1/connection.autoconnect-priority"
  printf '%s:5180 MHz:72\n%s:2437 MHz:80\n' "$F1" "$F1" > "$FAKE_STATE/scan"
  : > "$FAKE_STATE/calls.log"
  export TVSAVER_ENV_FILE="$FAKE_STATE/env"
  export TVSAVER_LIB_DIR="$FAKE_STATE/lib" TVSAVER_UNIT_DIR="$FAKE_STATE/units"
  export TVSAVER_LOCK_FILE="$FAKE_STATE/lock"
}
p() { cat "$FAKE_STATE/prof/$1/$2" 2>/dev/null; }
setup() { bash "$PI/setup_wifi.sh" "$@" 2>&1; }
is() { [ "$1" = "$2" ]; }

# 1. first run configures everything; second run reports no changes
new_state
out="$(setup)"; rc=$?
check "first run succeeds" is "$rc" 0
check "floor1 priority 100" is "$(p $F1 connection.autoconnect-priority)" 100
check "floor1 retries 0" is "$(p $F1 connection.autoconnect-retries)" 0
check "floor2 priority 10" is "$(p $F2 connection.autoconnect-priority)" 10
check "other wifi autoconnect no" is "$(p OtherWifi connection.autoconnect)" no
check "wired profile untouched" is "$(p 'Wired connection 1' connection.autoconnect-priority)" -999
check "timer enabled" test -f "$FAKE_STATE/timer_on"
check "units and script installed" test -f "$FAKE_STATE/units/tvsaver-wifi-prefer.timer" -a -x "$FAKE_STATE/lib/wifi_prefer.sh"
check "5 GHz strong -> band a" is "$(p $F1 802-11-wireless.band)" a
out2="$(setup)"
check "second run says no changes" has "$out2" "no changes"
: > "$FAKE_STATE/calls.log"; setup >/dev/null
check "second run makes no modify/enable calls" nofile_has "$FAKE_STATE/calls.log" 'connection (modify|edit)|systemctl enable'

# 2. band lock rule
new_state; printf '%s:5180 MHz:35\n%s:2437 MHz:90\n' "$F1" "$F1" > "$FAKE_STATE/scan"
out="$(setup)"
check "5 GHz weak -> band unset" is "$(p $F1 802-11-wireless.band)" ""
check "5 GHz weak -> warning" has "$out" "warning"
new_state; printf '%s:2437 MHz:90\n' "$F1" > "$FAKE_STATE/scan"
out="$(setup)"
check "2.4 GHz only -> band unset" is "$(p $F1 802-11-wireless.band)" ""
check "2.4 GHz only -> warning" has "$out" "band lock not set"
new_state; printf 'Other:5180 MHz:90\n' > "$FAKE_STATE/scan"; setup >/dev/null
check "Floor 1 not visible -> band unset" is "$(p $F1 802-11-wireless.band)" ""
new_state; printf '%s:5180 MHz:40\n' "$F1" > "$FAKE_STATE/scan"; setup >/dev/null
check "signal exactly 40 -> band a" is "$(p $F1 802-11-wireless.band)" a

# 3. .env handling
new_state
out="$(setup)"; rc=$?
check ".env missing -> message" has "$out" "missing, saved PSKs left untouched"
check ".env missing -> no failure" is "$rc" 0
check ".env missing -> no psk written" is "$(p $F1 802-11-wireless-security.psk)" ""
new_state
printf 'WIFI_FLOOR1_PSK=%s\nWIFI_FLOOR2_PSK=\n' "$SECRET" > "$TVSAVER_ENV_FILE"
out="$(setup)"; : > "$FAKE_STATE/calls.log"; out2="$(setup)"
check "floor1 psk set from .env" is "$(p $F1 802-11-wireless-security.psk)" "$SECRET"
check "empty floor2 psk untouched" is "$(p $F2 802-11-wireless-security.psk)" ""
check "psk not in output (run 1)" nothas "$out" "$SECRET"
check "psk not in output (run 2)" nothas "$out2" "$SECRET"
check "psk not in nmcli argv" nofile_has "$FAKE_STATE/calls.log" "$SECRET"
check "rerun with psk: no changes" has "$out2" "no changes"
new_state; printf 'WIFI_FLOOR1_PSK=%s\n' "$SECRET" > "$TVSAVER_ENV_FILE"
out="$(setup --dry-run)"
check "dry-run with psk hides it" nothas "$out" "$SECRET"

# 4. dry run applies nothing
new_state
out="$(setup --dry-run)"
check "dry-run prints plan" has "$out" "would:"
check "dry-run: no profile change" is "$(p $F1 connection.autoconnect-priority)" ""
check "dry-run: no timer, no units" test ! -f "$FAKE_STATE/timer_on" -a ! -e "$FAKE_STATE/units"

# 5. missing profile and not root
new_state; rm -rf "${FAKE_STATE:?}/prof/$F1"
out="$(setup)"; rc=$?
check "missing Floor 1: non-zero" test "$rc" != 0
check "missing Floor 1: names profile" has "$out" "$F1"
check "missing Floor 1: nothing changed" test -z "$(p $F2 connection.autoconnect-priority)" -a ! -f "$FAKE_STATE/timer_on"
new_state
out="$(env -u TVSAVER_TEST bash "$PI/setup_wifi.sh" 2>&1)"; rc=$?
check "not root: non-zero" test "$rc" != 0
check "not root: says run with sudo" has "$out" "run with sudo"
check "not root: no changes" is "$(p $F1 connection.autoconnect-priority)" ""

# 6. timer decisions
prefer() { bash "$PI/wifi_prefer.sh" 2>&1; }
new_state; echo $F2 > "$FAKE_STATE/active"
out="$(prefer)"
check "Floor 2 + Floor 1 visible: up Floor 1" is "$(cat "$FAKE_STATE/up.log" 2>/dev/null)" "$F1"
check "Floor 2 + Floor 1 visible: journal line" has "$out" "switched to $F1"
new_state; echo $F2 > "$FAKE_STATE/active"; touch "$FAKE_STATE/up_fail"
out="$(prefer)"; rc=$?
check "up fails: rc 0" is "$rc" 0
check "up fails: stays on Floor 2" is "$(cat "$FAKE_STATE/active")" "$F2"
check "up fails: journal line" has "$out" "failed"
new_state; echo $F2 > "$FAKE_STATE/active"; printf 'Other:5180 MHz:80\n' > "$FAKE_STATE/scan"
out="$(prefer)"
check "Floor 1 not visible: no up" test ! -f "$FAKE_STATE/up.log"
check "Floor 1 not visible: logs decision" has "$out" "not visible"
new_state; echo $F1 > "$FAKE_STATE/active"
out="$(prefer)"
check "Floor 1 active: quiet" is "$out" ""
check "Floor 1 active: no rescan" nofile_has "$FAKE_STATE/calls.log" 'rescan'
new_state; echo $F2 > "$FAKE_STATE/active"; touch "$FAKE_STATE/lock_busy"
out="$(prefer)"
check "lock busy: does nothing" test -z "$out" -a ! -f "$FAKE_STATE/up.log"

# 7. review additions
new_state; echo a > "$FAKE_STATE/prof/$F1/802-11-wireless.band"
printf '%s:2437 MHz:90
' "$F1" > "$FAKE_STATE/scan"; out="$(setup)"
check "stale band lock cleared when ineligible" is "$(p $F1 802-11-wireless.band)" ""
check "stale band lock: warning kept" has "$out" "warning"
new_state; setup >/dev/null
check "floor2 retries 0" is "$(p $F2 connection.autoconnect-retries)" 0
new_state; printf 'WIFI_FLOOR1_PSK="%s"
WIFI_FLOOR2_PSK=
' "$SECRET" > "$TVSAVER_ENV_FILE"; setup >/dev/null
check "CRLF quoted PSK stored bare" is "$(p $F1 802-11-wireless-security.psk)" "$SECRET"
new_state; mkdir -p "$FAKE_STATE/prof/Custom1"; echo 802-11-wireless > "$FAKE_STATE/prof/Custom1/type"
printf 'WIFI_FLOOR1_SSID=Custom1
' > "$TVSAVER_ENV_FILE"; printf 'Custom1:5180 MHz:72
' > "$FAKE_STATE/scan"
setup >/dev/null
check "custom Floor 1 SSID gets priority 100" is "$(p Custom1 connection.autoconnect-priority)" 100
new_state; rm -rf "${FAKE_STATE:?}/prof/$F2"
out="$(setup)"; rc=$?
check "Floor 2 missing: rc 0" is "$rc" 0
check "Floor 2 missing: warning" has "$out" "warning: Wi-Fi profile not found: $F2"
check "Floor 2 missing: Floor 1 configured" is "$(p $F1 connection.autoconnect-priority)" 100
new_state; mkdir -p "$FAKE_STATE/blocker"; : > "$FAKE_STATE/blocker/file"
out="$(TVSAVER_LIB_DIR="$FAKE_STATE/blocker/file/sub" setup)"; rc=$?
check "install failure: non-zero" test "$rc" != 0
check "install failure: message" has "$out" "install failed"
check "install failure: timer not enabled" test ! -f "$FAKE_STATE/timer_on"

# timer additions
new_state; echo $F2 > "$FAKE_STATE/active"; printf '%s:5180 MHz:35
' "$F1" > "$FAKE_STATE/scan"
out="$(prefer)"
check "timer: weak signal does nothing" test ! -f "$FAKE_STATE/up.log"
new_state; echo $F2 > "$FAKE_STATE/active"; echo a > "$FAKE_STATE/prof/$F1/802-11-wireless.band"
printf '%s:2437 MHz:90
' "$F1" > "$FAKE_STATE/scan"; out="$(prefer)"
check "timer: 2.4 GHz only with band a does nothing" test ! -f "$FAKE_STATE/up.log"
new_state; echo $F2 > "$FAKE_STATE/active"; touch "$FAKE_STATE/up_fail"
out="$(prefer)"
check "timer: failure writes back-off stamp" test -s "$FAKE_STATE/tvsaver-wifi-prefer.failed"
rm -f "$FAKE_STATE/up.log"; out="$(prefer)"
check "timer: next run within 10 min skips" test ! -f "$FAKE_STATE/up.log"
check "timer: back-off logged" has "$out" "backing off"
echo $(( $(date +%s) - 700 )) > "$FAKE_STATE/tvsaver-wifi-prefer.failed"; out="$(prefer)"
check "timer: retries after back-off expires" test -f "$FAKE_STATE/up.log"
new_state; : > "$FAKE_STATE/active"
out="$(prefer)"
check "timer: no active Wi-Fi + eligible Floor 1 tries up" is "$(cat "$FAKE_STATE/up.log" 2>/dev/null)" "$F1"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
