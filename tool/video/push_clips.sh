#!/usr/bin/env bash
# Push the spike clips to the TV app's own external files dir.
#
#   bash tool/video/push_clips.sh [tv-ip[:port]]     (default 192.168.0.24:5555)
#
# Read-only apart from `adb push` into
# /sdcard/Android/data/com.codedbykay.tvsaver.tv/files/spike/ (the app's own dir).
# Checks the free space on the TV first (read-only `df`) and refuses when the
# clips exceed 1.5 GB in total or would leave less than 300 MB free. Changes no
# TV setting. Exit codes: 0 pushed, 1 error (nothing pushed when a check fails).

set -u
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: don't rewrite adb arguments.

export MSYS_NO_PATHCONV=1 # Git Bash on Windows: do not rewrite the /sdcard/... device paths.
DEVICE="${1:-192.168.0.24:5555}"
case "$DEVICE" in *:*) ;; *) DEVICE="$DEVICE:5555" ;; esac
PKG="com.codedbykay.tvsaver.tv"
DEST="/sdcard/Android/data/$PKG/files/spike"
MAX_BYTES=$((1500 * 1024 * 1024))
SPARE_BYTES=$((300 * 1024 * 1024))

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build/spike-media"

die() { echo "$*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || die "adb not found on PATH (Android SDK platform-tools)"

shopt -s nullglob
clips=("$SRC"/[1-5]-*.mp4)
[ "${#clips[@]}" -gt 0 ] || die "No clips in $SRC. Run: bash tool/video/generate_clips.sh"

total=0
for f in "${clips[@]}"; do total=$((total + $(wc -c <"$f"))); done
[ "$total" -le "$MAX_BYTES" ] || die "Clips total $((total / 1048576)) MB, above the 1.5 GB limit; nothing pushed."

connect_out="$(adb connect "$DEVICE" 2>&1 | tr -d '\r')"
case "$connect_out" in *"connected to"*) ;; *) die "TV not reachable at $DEVICE ($connect_out)" ;; esac
state="$(adb -s "$DEVICE" get-state 2>&1 | tr -d '\r')"
[ "$state" = "device" ] || die "TV not reachable at $DEVICE (adb state: $state)"

tv() { adb -s "$DEVICE" shell "$@" 2>&1 | tr -d '\r'; }

free_kb() { tv df -k /sdcard | awk 'NR>1 && $4 ~ /^[0-9]+$/ {print $4; exit}'; }

before="$(free_kb)"
[ -n "$before" ] || die "Could not read the free space on the TV (df -k /sdcard); nothing pushed."
need=$((total + SPARE_BYTES))
[ $((before * 1024)) -ge "$need" ] ||
  die "Not enough free space on the TV: $((before / 1024)) MB free, need $((need / 1048576)) MB. Nothing pushed."
echo "TV free space before: $((before / 1024)) MB; pushing $((total / 1048576)) MB"

tv pm path "$PKG" | grep -q package: ||
  die "TV Saver ($PKG) is not installed; install it first (BUILD_AND_DEPLOY.md section 5)."
tv mkdir -p "$DEST" >/dev/null
for f in "${clips[@]}"; do
  echo "push $(basename "$f")"
  local_path="$f"; command -v cygpath >/dev/null 2>&1 && local_path="$(cygpath -m "$f")"
  adb -s "$DEVICE" push "$local_path" "$DEST/" | tr -d '\r' | tail -n 1
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "adb push failed for $f"
done

after="$(free_kb)"
echo "Pushed to $DEST"
tv ls -l "$DEST"
if [ -n "$after" ]; then
  echo "TV free space after:  $((after / 1024)) MB (dropped $(((before - after) / 1024)) MB)"
fi
