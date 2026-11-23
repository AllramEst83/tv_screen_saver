#!/usr/bin/env bash
# Generate the five 3840x2160 HEVC test clips for the video-path spike (PC only).
#
#   bash tool/video/generate_clips.sh
#
# Writes to build/spike-media/ (git-ignored):
#   1-sdr-lines.mp4    HEVC Main10 SDR (BT.709), 1 px line pairs + gradient, 10 s
#   2-hdr10-lines.mp4  same pattern, HDR10 (PQ / BT.2020 + mastering metadata), 10 s
#   3-hlg-lines.mp4    same pattern, HLG (ARIB STD-B67 / BT.2020), 10 s
#   4-pan-23976.mp4    23.976 fps horizontal pan for judder, 10 s
#   5-loop-audio.mp4   10 s, AAC stereo noise bursts at every whole second
#                      (one starts exactly at the loop point) + frame counter
# Dolby Vision is out of scope (deferred).
#
# Needs ffmpeg: `winget install Gyan.FFmpeg` (open a new shell afterwards).
# Without ffmpeg it prints that command and exits 1 without writing anything.
# Clips are built in a temp dir and moved into place only when all five succeed,
# so a failure never leaves partial files. Existing clips are overwritten.

set -eu

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found on PATH. Install it with:" >&2
  echo "  winget install Gyan.FFmpeg" >&2
  echo "then open a new shell and run this script again." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/spike-media"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FF=(ffmpeg -hide_banner -loglevel error -y)
X265_BASE="profile=main10:preset=veryfast:crf=16:repeat-headers=1:keyint=30:min-keyint=30"
HDR10_PARAMS="$X265_BASE:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:hdr10=1:hdr10-opt=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400"
HLG_PARAMS="$X265_BASE:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited"
SDR_PARAMS="$X265_BASE:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited"

# A font for the frame counter (drawtext). Colon escaped for the filter graph.
FONT=""
for f in "C:/Windows/Fonts/arial.ttf" "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" "/Library/Fonts/Arial.ttf"; do
  if [ -f "$f" ]; then FONT="$f"; break; fi
done
[ -n "$FONT" ] || { echo "No font found for the frame counter (looked for Arial/DejaVu)." >&2; exit 1; }
FONT_FF="${FONT/:/\\:}"

echo "== test pattern (one frame): gradient on top, then 1 px detail =="
# Top quarter: horizontal gradient. Then 1 px columns, 1 px rows and a 1 px
# checkerboard: every band is exact per-pixel detail.
"${FF[@]}" -f lavfi -i "color=c=black:s=3840x2160:d=1,format=yuv444p" -frames:v 1 \
  -vf "geq=lum='if(lt(Y,H/4),255*X/W,if(lt(Y,H/2),255*mod(X,2),if(lt(Y,3*H/4),255*mod(Y,2),255*mod(X+Y,2))))':cb=128:cr=128" \
  "$TMP/pattern.png"

# Wide bars with 1 px lines on the stripes, used for the pan clip.
"${FF[@]}" -f lavfi -i "color=c=black:s=3840x2160:d=1,format=yuv444p" -frames:v 1 \
  -vf "geq=lum='if(lt(mod(floor(X/160),2),1),if(lt(mod(X,8),1),255,40),220)':cb=128:cr=128" \
  "$TMP/bars.png"

# Pattern clip: pattern still + a 64 px white square sweeping across so the
# video is not static (a static clip hides stutter and rate problems).
pattern_clip() { # name, x265 params, ffmpeg colour tags...
  local name="$1" params="$2"
  shift 2
  echo "== $name =="
  "${FF[@]}" -loop 1 -framerate 30 -t 10 -i "$TMP/pattern.png" \
    -f lavfi -i "color=c=white:s=64x64:r=30:d=10" \
    -filter_complex "[0:v][1:v]overlay=x='mod(t*384,3776)':y=1000,scale=in_range=full:out_range=limited,format=yuv420p10le" \
    -c:v libx265 -x265-params "$params" -tag:v hvc1 -an "$@" -movflags +faststart "$TMP/$name"
}
pattern_clip 1-sdr-lines.mp4 "$SDR_PARAMS" -color_primaries bt709 -color_trc bt709 -colorspace bt709
pattern_clip 2-hdr10-lines.mp4 "$HDR10_PARAMS" -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc
pattern_clip 3-hlg-lines.mp4 "$HLG_PARAMS" -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc

echo "== 4-pan-23976.mp4 =="
# 23.976 fps; the bars move 20 px per frame (about 480 px/s), wrapping every
# 320 px (the bar period), so the pan is continuous.
"${FF[@]}" -loop 1 -framerate 24000/1001 -t 10 -i "$TMP/bars.png" \
  -vf "pad=w=iw+320:h=ih:x=0:y=0,crop=w=3840:h=2160:x='mod(n*20,320)':y=0,scale=in_range=full:out_range=limited,format=yuv420p10le" \
  -r 24000/1001 -c:v libx265 -x265-params "$SDR_PARAMS" -tag:v hvc1 -an \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart "$TMP/4-pan-23976.mp4"

echo "== 5-loop-audio.mp4 =="
# testsrc2 has motion; the big counter shows the frame number so a loop-point
# black frame or repeated frame is visible. Noise bursts (0.15 s every second,
# first burst at t=0) so a gap or click at the loop point is audible.
"${FF[@]}" -f lavfi -i "testsrc2=s=3840x2160:r=30:d=10" \
  -f lavfi -i "anoisesrc=d=10:c=pink:r=48000:a=0.5,volume='if(lt(mod(t,1),0.15),1,0)':eval=frame,aformat=sample_fmts=fltp:channel_layouts=stereo" \
  -vf "drawtext=fontfile='$FONT_FF':text='%{frame_num}':start_number=0:x=(w-text_w)/2:y=(h-text_h)/2:fontsize=480:fontcolor=white:box=1:boxcolor=black@0.7:boxborderw=40,format=yuv420p10le" \
  -c:v libx265 -x265-params "$SDR_PARAMS" -tag:v hvc1 \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac -b:a 192k -ar 48000 -ac 2 -t 10 -movflags +faststart "$TMP/5-loop-audio.mp4"

echo "== moving into $OUT =="
mkdir -p "$OUT"
for f in "$TMP"/[1-5]-*.mp4; do mv -f "$f" "$OUT/"; done
ls -l "$OUT"
