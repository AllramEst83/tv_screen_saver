#!/usr/bin/env bash
# Generate photos for the soak run (story 5-4), PC only.
#
#   bash tool/video/generate_photos.sh
#
# Writes to build/soak-media/ (git-ignored), all JPEG at quality 95:
#   soak-photo-1-chart-4000x3000.jpg   1 px line pairs and a gradient (the
#                                      test chart of media-fidelity.md)
#   soak-photo-2-big-6000x4000.jpg     larger than 4096 px: the phone scales it
#   soak-photo-3-portrait-3000x4000.jpg  portrait
#   soak-photo-4-bars-4000x3000.jpg    wide bars with 1 px lines
#   soak-photo-5-colour-4000x3000.jpg  colour ramps (look for banding)
#
# Needs ffmpeg: `winget install Gyan.FFmpeg` (open a new shell afterwards).
# Without ffmpeg it prints that command and exits 1 without writing anything.
# Files are built in a temp dir and moved into place only when all succeed.

set -eu

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found on PATH. Install it with:" >&2
  echo "  winget install Gyan.FFmpeg" >&2
  echo "then open a new shell and run this script again." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${SOAK_MEDIA_DIR:-$ROOT/build/soak-media}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FF=(ffmpeg -hide_banner -loglevel error -y)

photo() { # name, size, geq luma expression, [cb] [cr]
  local name="$1" size="$2" lum="$3" cb="${4:-128}" cr="${5:-128}"
  echo "== $name =="
  "${FF[@]}" -f lavfi -i "color=c=black:s=$size:d=1,format=yuv444p" -frames:v 1 \
    -vf "geq=lum='$lum':cb='$cb':cr='$cr',format=yuvj420p" -q:v 2 "$TMP/$name"
}

photo soak-photo-1-chart-4000x3000.jpg 4000x3000 \
  'if(lt(Y,H/4),255*X/W,if(lt(Y,H/2),255*mod(X,2),if(lt(Y,3*H/4),255*mod(Y,2),255*mod(X+Y,2))))'
photo soak-photo-2-big-6000x4000.jpg 6000x4000 \
  'if(lt(Y,H/4),255*X/W,if(lt(Y,H/2),255*mod(X,2),if(lt(Y,3*H/4),255*mod(Y,2),255*mod(X+Y,2))))'
photo soak-photo-3-portrait-3000x4000.jpg 3000x4000 \
  'if(lt(Y,H/4),255*X/W,if(lt(Y,H/2),255*mod(X,2),if(lt(Y,3*H/4),255*mod(Y,2),255*mod(X+Y,2))))'
photo soak-photo-4-bars-4000x3000.jpg 4000x3000 \
  'if(lt(mod(floor(X/160),2),1),if(lt(mod(X,8),1),255,40),220)'
photo soak-photo-5-colour-4000x3000.jpg 4000x3000 \
  '128+100*sin(X/300)*cos(Y/220)' '128+120*X/W' '255*Y/H'

mkdir -p "$OUT"
mv "$TMP"/soak-photo-*.jpg "$OUT"/
echo "Done: $OUT"
ls -l "$OUT"/soak-photo-*.jpg
