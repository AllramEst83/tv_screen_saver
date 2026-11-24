#!/usr/bin/env bash
# Put the soak media on the Pi (story 5-4). PC side.
#
#   PI_HOST=<pi address> PI_TOKEN=<static token> bash tool/soak/prepare_soak.sh [--dry-run]
#
# 1. makes the test clips (tool/video/generate_clips.sh) and photos
#    (tool/video/generate_photos.sh) when they are not there yet,
# 2. uploads every clip (the HDR10, HLG, SDR, pan and loop clips) and every
#    photo to the Pi with the resumable uploader. Files the Pi already has are
#    skipped, so the script can be run again after an interruption.
#
# It does not make the playlist: open the phone app, Playlists, New playlist,
# name it "Soak", add everything from the library (photos and clips mixed),
# keep Shuffle off, and press play. See BUILD_AND_DEPLOY.md section 16.
#
# The token is the Pi's static token (~/.config/tvsaver/token on the Pi); it is
# only sent to the Pi, never printed.

set -eu

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: PI_HOST=... PI_TOKEN=... bash prepare_soak.sh [--dry-run]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLIPS="${SOAK_CLIPS_DIR:-$ROOT/build/spike-media}"
PHOTOS="${SOAK_MEDIA_DIR:-$ROOT/build/soak-media}"
HOST="${PI_HOST:-}"
TOKEN="${PI_TOKEN:-}"

if [ "$DRY" = 0 ]; then
  [ -n "$HOST" ] || { echo "set PI_HOST to the Pi's address" >&2; exit 2; }
  [ -n "$TOKEN" ] || { echo "set PI_TOKEN to the Pi's static token" >&2; exit 2; }
fi

ls "$CLIPS"/*.mp4 >/dev/null 2>&1 || {
  echo "no clips yet: making them"
  [ "$DRY" = 1 ] && echo "[dry-run] would run tool/video/generate_clips.sh" || bash "$ROOT/tool/video/generate_clips.sh"
}
ls "$PHOTOS"/soak-photo-*.jpg >/dev/null 2>&1 || {
  echo "no photos yet: making them"
  [ "$DRY" = 1 ] && echo "[dry-run] would run tool/video/generate_photos.sh" || bash "$ROOT/tool/video/generate_photos.sh"
}

failed=0
for f in "$CLIPS"/*.mp4 "$PHOTOS"/soak-photo-*.jpg; do
  [ -f "$f" ] || continue
  if [ "$DRY" = 1 ]; then
    echo "[dry-run] would upload $(basename "$f")"
    continue
  fi
  echo "== $(basename "$f") =="
  set +e
  (cd "$ROOT/packages/hub_core" && dart run tool/upload.dart "$f" --host "$HOST" --token "$TOKEN")
  code=$?
  set -e
  case "$code" in
    0) ;;
    2) echo "   already on the Pi" ;;
    *) echo "   upload failed (exit $code)" >&2; failed=1 ;;
  esac
done

[ "$failed" = 0 ] || { echo "Some uploads failed; run this again." >&2; exit 1; }
echo "Done. Now make the playlist 'Soak' in the phone app and press play."
