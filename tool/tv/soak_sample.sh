#!/usr/bin/env bash
# Sample the TV while the soak runs (story 5-4). Read-only: it never installs,
# launches, stops or changes anything on the TV.
#
#   tool/tv/soak_sample.sh [tv-ip[:port]] [--interval SECONDS] [--count N]
#
# Defaults: 192.168.0.24:5555, every 900 s (15 min), until you press Ctrl-C.
# Every sample is one tab-separated line in build/measurements/soak-<start>.tsv:
#   time  elapsed_s  OK  pss_kb  java_kb  native_kb  wakefulness  focus  alive
# or, when the TV could not be read:
#   time  elapsed_s  FAIL  reason
# A failed sample never stops the run; the next one reconnects first.
#
# Reads only: dumpsys meminfo / power / window and pidof.
# Judge the file with tool/tv/soak_report.sh.

set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite adb arguments.

DEVICE="192.168.0.24:5555"
INTERVAL=900
COUNT=0
PKG="${SOAK_PKG:-com.codedbykay.tvsaver.tv}"

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --count) COUNT="${2:?--count needs a number}"; shift 2 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) DEVICE="$1"; shift ;;
  esac
done
case "$DEVICE" in *:*) ;; *) DEVICE="$DEVICE:5555" ;; esac
case "$INTERVAL$COUNT" in *[!0-9]*) echo "--interval and --count must be whole numbers" >&2; exit 2 ;; esac

command -v adb >/dev/null 2>&1 || {
  echo "adb not found on PATH (Android SDK platform-tools)" >&2
  exit 1
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${SOAK_OUT_DIR:-$ROOT/build/measurements}"
START_EPOCH="$(date +%s)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/soak-$STAMP.tsv"
mkdir -p "$OUT_DIR"
{
  printf '# soak-sampler start=%s device=%s pkg=%s interval=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$DEVICE" "$PKG" "$INTERVAL"
  printf '# time\telapsed_s\tstatus\tpss_kb\tjava_kb\tnative_kb\twakefulness\tfocus\talive\n'
} >"$OUT"

tv() { adb -s "$DEVICE" shell "$@" 2>&1 | tr -d '\r'; }

# First number after a label in the meminfo text, or empty.
mem() { # label text
  printf '%s\n' "$2" | grep -m1 -E "$1" | grep -oE '[0-9]+' | head -n 1
}

sample() {
  local now elapsed state meminfo power window pid pss java native wake focus alive
  now="$(date '+%Y-%m-%dT%H:%M:%S')"
  elapsed=$(($(date +%s) - START_EPOCH))
  adb connect "$DEVICE" >/dev/null 2>&1
  state="$(adb -s "$DEVICE" get-state 2>&1 | tr -d '\r')"
  if [ "$state" != "device" ]; then
    printf '%s\t%s\tFAIL\tadb state: %s\n' "$now" "$elapsed" "${state:-none}" >>"$OUT"
    echo "$now  sample failed (adb state: ${state:-none})"
    return
  fi
  pid="$(tv pidof "$PKG")"
  alive=0
  [ -n "$pid" ] && alive=1
  meminfo="$(tv dumpsys meminfo "$PKG")"
  pss="$(mem 'TOTAL PSS:|^ *TOTAL ' "$meminfo")"
  java="$(mem 'Java Heap:' "$meminfo")"
  native="$(mem 'Native Heap:' "$meminfo")"
  power="$(tv dumpsys power)"
  wake="$(printf '%s\n' "$power" | grep -m1 -oE 'mWakefulness=[A-Za-z]+' | cut -d= -f2)"
  window="$(tv dumpsys window)"
  focus="$(printf '%s\n' "$window" | grep -m1 'mCurrentFocus' | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+' | head -n 1)"
  if [ "$alive" = 1 ] && [ -z "$pss" ]; then
    printf '%s\t%s\tFAIL\tno meminfo for %s\n' "$now" "$elapsed" "$PKG" >>"$OUT"
    echo "$now  sample failed (no meminfo)"
    return
  fi
  printf '%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$now" "$elapsed" "${pss:-0}" "${java:-0}" "${native:-0}" "${wake:-unknown}" \
    "${focus:-none}" "$alive" >>"$OUT"
  echo "$now  pss=$((${pss:-0} / 1024)) MB  wake=${wake:-?}  alive=$alive"
}

echo "Sampling $PKG on $DEVICE every ${INTERVAL}s into $OUT (Ctrl-C to stop)"
n=0
while :; do
  sample
  n=$((n + 1))
  [ "$COUNT" -gt 0 ] && [ "$n" -ge "$COUNT" ] && break
  [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done
echo "Samples: $OUT"
