#!/usr/bin/env bash
# Judge a soak run (story 5-4).
#
#   tool/tv/soak_report.sh <soak-*.tsv> [playback.csv]
#
# Reads the sampler's file (tool/tv/soak_sample.sh) and, when given, the app's
# own playback log (pulled from the TV, see BUILD_AND_DEPLOY.md). Prints the
# duration, every interruption with its time, the PSS of the first and the
# last hour and the trend in MB per hour.
#
# An interruption is a sample where the app was not running, the screen was not
# awake, or another app had the focus; and, from the playback log, any
# `paused`, `hidden` or `detached` event. A sample the PC could not take (the
# adb link) is reported but is not an interruption.
#
# PASS: no interruption, trend below 10 MB/h and last hour less than 100 MB
# above the first hour. It needs at least 2 h of samples.
#
# Exit codes: 0 pass, 1 fail, 2 usage, 3 not enough data.

set -u

[ $# -ge 1 ] && [ -r "$1" ] || {
  echo "usage: soak_report.sh <soak-*.tsv> [playback.csv]" >&2
  exit 2
}
SAMPLES="$1"
LOG="${2:-}"
[ -z "$LOG" ] || [ -r "$LOG" ] || {
  echo "cannot read $LOG" >&2
  exit 2
}

PKG="$(sed -n 's/^# soak-sampler .*pkg=\([^ ]*\).*/\1/p' "$SAMPLES" | head -n 1)"
PKG="${PKG:-com.codedbykay.tvsaver.tv}"

awk -F'\t' -v pkg="$PKG" -v logfile="$LOG" '
function mb(kb) { return kb / 1024 }
BEGIN { n = 0; fails = 0; ints = 0 }
/^#/ || NF < 3 { next }
$3 == "FAIL" { fails++; failrows[fails] = $1 " (" $4 ")"; next }
$3 == "OK" {
  n++
  t[n] = $2 + 0
  pss[n] = $4 + 0
  stamp[n] = $1
  bad = ""
  if ($9 != 1) bad = "the app was not running"
  else if ($7 != "Awake") bad = "the screen was " $7
  else if (index($8, pkg) == 0) bad = "another window had the focus (" $8 ")"
  if (bad != "") { ints++; intr[ints] = $1 "  " bad }
}
END {
  if (n == 0) { print "no samples"; exit 3 }
  last = t[n]
  print "Samples:        " n " (" fails " failed to read)"
  printf "Duration:       %dh %02dm\n", int(last / 3600), int((last % 3600) / 60)
  for (i = 1; i <= fails; i++) print "  could not sample: " failrows[i]

  # The playback log: lifecycle events that mean the picture was interrupted.
  if (logfile != "") {
    while ((getline line < logfile) > 0) {
      split(line, f, ",")
      if (f[2] == "paused" || f[2] == "hidden" || f[2] == "detached") {
        ints++
        intr[ints] = f[1] "  app " f[2] " (playback log)"
      }
    }
  }
  print "Interruptions:  " ints
  for (i = 1; i <= ints; i++) print "  " intr[i]

  if (last < 7200) {
    print "Trend:          not enough data for a trend (need 2 h or more)"
    exit 3
  }
  fs = 0; fn = 0; ls = 0; ln = 0
  sx = 0; sy = 0; sxx = 0; sxy = 0
  for (i = 1; i <= n; i++) {
    if (t[i] <= 3600) { fs += pss[i]; fn++ }
    if (t[i] >= last - 3600) { ls += pss[i]; ln++ }
    x = t[i] / 3600; y = mb(pss[i])
    sx += x; sy += y; sxx += x * x; sxy += x * y
  }
  den = n * sxx - sx * sx
  slope = den == 0 ? 0 : (n * sxy - sx * sy) / den
  firstmean = fn ? mb(fs / fn) : 0
  lastmean = ln ? mb(ls / ln) : 0
  growth = lastmean - firstmean
  printf "First hour:     %.0f MB (mean PSS, %d samples)\n", firstmean, fn
  printf "Last hour:      %.0f MB (mean PSS, %d samples)\n", lastmean, ln
  printf "Growth:         %+.0f MB\n", growth
  printf "Trend:          %+.1f MB/h\n", slope
  ok = (ints == 0 && slope < 10 && growth < 100)
  print ok ? "Result:         PASS" : "Result:         FAIL"
  if (ints > 0) print "  an interruption means the TV settings in lan-setup.md are not enough"
  if (slope >= 10) print "  memory grows by 10 MB/h or more"
  if (growth >= 100) print "  the last hour is 100 MB or more above the first"
  exit ok ? 0 : 1
}
' "$SAMPLES"
