#!/usr/bin/env bash
# Measure what the TV really renders, read-only.
#
#   tool/tv/display_report.sh [tv-ip[:port]]     (default 192.168.0.24:5555)
#
# Connects over adb, makes sure the TV Saver app has logged its DisplayReport
# line (launching the app if needed, waiting up to 15 s), and writes one report
# file with that line plus `wm size`, `wm density` and `dumpsys display`
# (display modes, HDR capabilities) to build/measurements/.
#
# It installs nothing and never changes a TV setting: only read commands
# (wm size / wm density without arguments, dumpsys, getprop, pm path, pidof,
# logcat -d) plus launching the app. If the app is running but its line is no
# longer in the logcat buffer, the app is restarted to log it again.
#
# Exit codes: 0 report complete, 1 TV not reachable (no file written),
# 2 report written but the app line is missing.

set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite adb arguments.

DEVICE="${1:-192.168.0.24:5555}"
case "$DEVICE" in *:*) ;; *) DEVICE="$DEVICE:5555" ;; esac
PKG="com.codedbykay.tvsaver.tv"
WAIT_SECONDS=15

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT/build/measurements"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/display-report-$STAMP.txt"

unreachable() {
  echo "TV not reachable at $DEVICE${1:+ ($1)}" >&2
  exit 1
}

command -v adb >/dev/null 2>&1 || {
  echo "adb not found on PATH (Android SDK platform-tools)" >&2
  exit 1
}

connect_out="$(adb connect "$DEVICE" 2>&1 | tr -d '\r')"
case "$connect_out" in
  *"connected to"*) ;;
  *) unreachable "$connect_out" ;;
esac
state="$(adb -s "$DEVICE" get-state 2>&1 | tr -d '\r')"
[ "$state" = "device" ] || unreachable "adb state: $state; accept the debugging prompt on the TV"

tv() { adb -s "$DEVICE" shell "$@" 2>&1 | tr -d '\r'; }

# Last DisplayReport line logged by the running app process, if any.
app_line() {
  local pid
  pid="$(tv pidof "$PKG")"
  [ -n "$pid" ] || return 0
  adb -s "$DEVICE" logcat -d --pid="$pid" -s flutter 2>/dev/null | tr -d '\r' |
    grep -o 'DisplayReport: .*' | tail -n 1
}

launch_app() {
  tv monkey -p "$PKG" -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null
}

# --- Make sure the app line is there -----------------------------------------
notes=()
line=""
installed="$(tv pm path "$PKG")"
if [ -z "$installed" ]; then
  notes+=("$PKG is not installed on the TV (see BUILD_AND_DEPLOY.md).")
else
  line="$(app_line)"
  if [[ "$line" != "DisplayReport: renders"* ]]; then
    if [ -n "$(tv pidof "$PKG")" ]; then
      notes+=("App was running without a DisplayReport line in logcat; restarted it.")
      tv am force-stop "$PKG" >/dev/null
    else
      notes+=("App was not running; launched it.")
    fi
    launch_app
    for _ in $(seq "$WAIT_SECONDS"); do
      sleep 1
      line="$(app_line)"
      [[ "$line" == "DisplayReport: renders"* ]] && break
    done
  fi
fi

missing=0
if [[ "$line" != "DisplayReport: renders"* ]]; then
  missing=1
  notes+=("app line missing (no 'DisplayReport: renders' line within ${WAIT_SECONDS} s${line:+; last line: $line})")
fi

# --- Collect ------------------------------------------------------------------
mkdir -p "$OUT_DIR"
TMP="$OUT.partial"
trap 'rm -f "$TMP"' EXIT

display_dump="$(tv dumpsys display)"
wm_size="$(tv wm size)"
wm_density="$(tv wm density)"

{
  echo "== TV Saver display report =="
  echo "Date:     $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Device:   $DEVICE"
  echo "Model:    $(tv getprop ro.product.manufacturer) $(tv getprop ro.product.model)"
  echo "Android:  $(tv getprop ro.build.version.release) (SDK $(tv getprop ro.build.version.sdk))"
  echo "App:      $PKG $(tv dumpsys package "$PKG" | grep -oE 'versionName=[^ ]+|versionCode=[0-9]+' | sort -u | tr '\n' ' ')"
  echo
  echo "== DisplayReport (app log) =="
  if [ "$missing" -eq 0 ]; then echo "$line"; else echo "app line missing"; fi
  for n in "${notes[@]+"${notes[@]}"}"; do echo "Note: $n"; done
  echo
  echo "== wm size =="
  echo "$wm_size"
  echo
  echo "== wm density =="
  echo "$wm_density"
  echo
  echo "== Display modes and HDR capabilities (from dumpsys display) =="
  # Unique matches in order of appearance. HDR types: 1 Dolby Vision, 2 HDR10,
  # 3 HLG, 4 HDR10+.
  echo "$display_dump" | grep -oE \
    -e 'supportedModes \[(\{[^}]*\}(, )?)*\]' \
    -e '(mActiveSfDisplayMode=)?DisplayMode\{[^}]*\}' \
    -e '(mActiveModeId|mDefaultModeId|m?UserPreferredModeId)=-?[0-9]+' \
    -e 'HdrCapabilities\{[^}]*\}' \
    -e '[A-Za-z]*HdrTypes \[[^]]*\]' \
    -e 'supportedColorModes \[[^]]*\]' |
    awk '!seen[$0]++'
  echo
  echo "== dumpsys display (full) =="
  echo "$display_dump"
} >"$TMP"
mv "$TMP" "$OUT"
trap - EXIT

# --- Summary ------------------------------------------------------------------
echo "TV:            $DEVICE"
if [ "$missing" -eq 0 ]; then
  echo "App:           $line"
else
  echo "App:           app line missing"
fi
echo "$wm_size" | sed 's/^/wm size:       /'
echo "$wm_density" | sed 's/^/wm density:    /'
for n in "${notes[@]+"${notes[@]}"}"; do echo "Note:          $n"; done
echo "Report:        $OUT"

exit $((missing * 2))
