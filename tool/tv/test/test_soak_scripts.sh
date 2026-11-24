#!/usr/bin/env bash
# Regression tests for soak_sample.sh and soak_report.sh with a fake adb on
# PATH. No TV, no network.
#   bash tool/tv/test/test_soak_scripts.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TV="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0; PASSES=0
TAB=$'	'
check() { local n="$1"; shift; if "$@"; then PASSES=$((PASSES + 1)); echo "ok   $n"; else FAILS=$((FAILS + 1)); echo "FAIL $n"; fi; }

# ---------------------------------------------------------------- fake adb
mkdir -p "$T/bin"
cat >"$T/bin/adb" <<'FAKE'
#!/usr/bin/env bash
echo "adb $*" >>"$FAKE_STATE/calls.log"
[ "${1:-}" = connect ] && { echo "connected to $2"; exit 0; }
[ "${1:-}" = -s ] && shift 2
case "$1" in
  get-state) [ -e "$FAKE_STATE/offline" ] && echo "offline" || echo "device"; exit 0 ;;
  shell) shift ;;
  *) exit 0 ;;
esac
case "$1" in
  pidof) [ -e "$FAKE_STATE/dead" ] || echo "4321" ;;
  dumpsys)
    case "$2" in
      meminfo) [ -e "$FAKE_STATE/nomem" ] || printf '** MEMINFO in pid 4321 [x] **\n  Java Heap:    20480\n Native Heap:    51200\n           TOTAL PSS:   307200            TOTAL RSS:  400000\n' ;;
      power) echo "  mWakefulness=$(cat "$FAKE_STATE/wake" 2>/dev/null || echo Awake)" ;;
      window) echo "  mCurrentFocus=Window{abc u0 com.codedbykay.tvsaver.tv/com.codedbykay.tvsaver.MainActivity}" ;;
    esac ;;
esac
FAKE
chmod +x "$T/bin/adb"
export FAKE_STATE="$T/state"; mkdir -p "$FAKE_STATE"
export PATH="$T/bin:$PATH" SOAK_OUT_DIR="$T/out"

# ----------------------------------------------------------------- sampler
out="$(bash "$TV/soak_sample.sh" 1.2.3.4 --interval 0 --count 2)"
file="$(ls "$T/out"/soak-*.tsv)"
check "sampler writes a file" test -f "$file"
check "header names the package" grep -q 'pkg=com.codedbykay.tvsaver.tv' "$file"
check "two OK rows" test "$(grep -c "${TAB}OK${TAB}" "$file")" = 2
check "row has pss java native wake focus alive" grep -q "${TAB}OK${TAB}307200${TAB}20480${TAB}51200${TAB}Awake${TAB}com.codedbykay.tvsaver.tv/com.codedbykay.tvsaver.MainActivity${TAB}1\$" "$file"
check "port 5555 is added" grep -q 'adb connect 1.2.3.4:5555' "$FAKE_STATE/calls.log"
check "it only reads" bash -c "! grep -E 'install|uninstall|am force|monkey|settings put|wm size [0-9]|input |reboot|pm ' '$FAKE_STATE/calls.log'"

touch "$FAKE_STATE/offline"
bash "$TV/soak_sample.sh" 1.2.3.4 --interval 0 --count 1 >/dev/null
sleep 1
file2="$(ls -t "$T/out"/soak-*.tsv | head -n 1)"
check "a lost adb link is a FAIL row, not a crash" grep -q "${TAB}FAIL${TAB}adb state: offline" "$file2"
rm "$FAKE_STATE/offline"

touch "$FAKE_STATE/dead"
bash "$TV/soak_sample.sh" 1.2.3.4 --interval 0 --count 1 >/dev/null
file3="$(ls -t "$T/out"/soak-*.tsv | head -n 1)"
check "a dead app is alive=0" grep -q "${TAB}0\$" "$file3"
rm "$FAKE_STATE/dead"
check "bad option is an error" bash -c "! bash '$TV/soak_sample.sh' --nope >/dev/null 2>&1"
check "bad number is an error" bash -c "! bash '$TV/soak_sample.sh' --interval x >/dev/null 2>&1"

# ------------------------------------------------------------------ report
# row <elapsed_s> <pss_kb> [wake] [alive] [focus]
row() {
  printf '2026-11-24T10:00:00\t%s\tOK\t%s\t0\t0\t%s\t%s\t%s\n' "$1" "$2" "${3:-Awake}" "${5:-com.codedbykay.tvsaver.tv/Main}" "${4:-1}"
}
make() { # name, then lines on stdin
  { echo '# soak-sampler start=2026-11-24T10:00:00 device=x pkg=com.codedbykay.tvsaver.tv interval=3600'; cat; } >"$T/$1"
}
flat() { for h in 0 1 2 3 4 5 6 7 8; do row $((h * 3600)) $((300000 + (h % 2) * 2000)); done; }

flat | make pass.tsv
r="$(bash "$TV/soak_report.sh" "$T/pass.tsv")"; code=$?
check "a flat 8 h run passes" test "$code" = 0
check "pass prints the duration" grep -q 'Duration:       8h 00m' <<<"$r"
check "pass prints PASS" grep -q 'Result:         PASS' <<<"$r"
check "no interruptions" grep -q 'Interruptions:  0' <<<"$r"

for h in 0 1 2 3 4 5 6 7 8; do row $((h * 3600)) $((300000 + h * 30000)); done | make leak.tsv
r="$(bash "$TV/soak_report.sh" "$T/leak.tsv")"; code=$?
check "a leak fails" test "$code" = 1
check "the leak is named" grep -q 'memory grows' <<<"$r"
check "the trend is about 29 MB/h" grep -q 'Trend:          +29' <<<"$r"

{ flat; row 14400 301000 Dozing; row 18000 301000 Awake 0; row 21600 301000 Awake 1 'com.other/Main'; } | make interrupted.tsv
r="$(bash "$TV/soak_report.sh" "$T/interrupted.tsv")"; code=$?
check "interruptions fail the run" test "$code" = 1
check "the screen going to sleep is named" grep -q 'the screen was Dozing' <<<"$r"
check "the app dying is named" grep -q 'the app was not running' <<<"$r"
check "another window is named" grep -q 'another window had the focus' <<<"$r"

for h in 0 1; do row $((h * 3600)) 300000; done | make short.tsv
r="$(bash "$TV/soak_report.sh" "$T/short.tsv")"; code=$?
check "a short run says so and exits 3" test "$code" = 3
check "short run message" grep -q 'not enough data for a trend' <<<"$r"

{ flat; printf '2026-11-24T11:00:00\t5000\tFAIL\tadb state: offline\n'; } | make failed.tsv
r="$(bash "$TV/soak_report.sh" "$T/failed.tsv")"; code=$?
check "a failed sample is shown but is no interruption" test "$code" = 0
check "failed sample listed" grep -q 'could not sample' <<<"$r"

printf '2026-11-24T12:00:00,resumed,a.jpg,playing,\n2026-11-24T13:00:00,paused,a.jpg,playing,\n' >"$T/playback.csv"
r="$(bash "$TV/soak_report.sh" "$T/pass.tsv" "$T/playback.csv")"; code=$?
check "the app log can add an interruption" test "$code" = 1
check "it is named" grep -q 'app paused (playback log)' <<<"$r"

check "no argument is a usage error" bash -c "bash '$TV/soak_report.sh' >/dev/null 2>&1; test \$? = 2"
: >"$T/empty.tsv"
check "an empty file is not enough data" bash -c "bash '$TV/soak_report.sh' '$T/empty.tsv' >/dev/null 2>&1; test \$? = 3"

echo "passed $PASSES, failed $FAILS"
test "$FAILS" = 0
