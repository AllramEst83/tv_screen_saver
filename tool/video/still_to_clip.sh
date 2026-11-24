#!/usr/bin/env bash
# Turn a still image into a 4K HEVC clip (story 7-1, optional). PC only.
#
#   bash tool/video/still_to_clip.sh <image> [seconds] [out-dir]
#
# Writes <out-dir>/<name>-4k.mp4 (default out-dir: build/still-clips/): the
# picture fitted into 3840x2160 on black, HEVC Main10, SDR (BT.709), 24 fps,
# `seconds` long (default 10), no audio. The TV plays it through the video path
# like any clip, so it is shown by the hardware video decoder at 3840x2160.
# That is an alternative to the native photo path (story 5-3) for a picture
# that must look exactly the same on every TV.
#
# The Pi does no transcoding: copy the clip into the inbox share
# (\gemini-pi.local\inbox) or upload it from the phone. It then appears in the
# library as a video.
#
# Needs ffmpeg: `winget install Gyan.FFmpeg` (open a new shell afterwards).
# Without ffmpeg it prints that command and exits 1 without writing anything.

set -eu

if [ $# -lt 1 ] || [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,19p' "$0"
  [ $# -lt 1 ] && exit 2 || exit 0
fi

IMAGE="$1"
SECONDS_LONG="${2:-10}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${3:-$ROOT/build/still-clips}"

case "$SECONDS_LONG" in
  '' | *[!0-9]*) echo "seconds must be a whole number" >&2; exit 2 ;;
esac
[ "$SECONDS_LONG" -ge 1 ] && [ "$SECONDS_LONG" -le 3600 ] || {
  echo "seconds must be from 1 to 3600" >&2
  exit 2
}
[ -f "$IMAGE" ] || { echo "no such image: $IMAGE" >&2; exit 2; }

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found on PATH. Install it with:" >&2
  echo "  winget install Gyan.FFmpeg" >&2
  echo "then open a new shell and run this script again." >&2
  exit 1
fi

name="$(basename "$IMAGE")"
name="${name%.*}"
mkdir -p "$OUT_DIR"
out="$OUT_DIR/$name-4k.mp4"
tmp="$out.partial.mp4"
trap 'rm -f "$tmp"' EXIT

ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 24 -t "$SECONDS_LONG" -i "$IMAGE" \
  -vf "scale=3840:2160:force_original_aspect_ratio=decrease:flags=lanczos,pad=3840:2160:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p10le" \
  -c:v libx265 -x265-params "profile=main10:preset=slow:crf=14:keyint=48:min-keyint=48:repeat-headers=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited" \
  -tag:v hvc1 -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an -movflags +faststart "$tmp"
mv "$tmp" "$out"
trap - EXIT
echo "Wrote $out ($(($(wc -c <"$out") / 1024)) KB)"
echo "Next: copy it to the inbox share or upload it from the phone."
