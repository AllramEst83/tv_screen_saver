---
title: '4K still-as-HEVC clip mode (optional)'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '255e1e4'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** (optional) A picture shown through the photo path depends on how the TV scales and decodes it.

**Approach:** A PC script turns a still into a 3840x2160 HEVC clip; the Pi stays free of transcoding and imports it through the inbox like any video.

## Implementation Notes

- `tool/video/still_to_clip.sh`: fit into 3840x2160 on black with lanczos, `libx265` Main10 crf 14, `hvc1`, BT.709 tagged, 24 fps, keyframe every 2 s, no audio, written to a partial file and moved when done. Arguments are checked (exit 2), no ffmpeg gives the install hint (exit 1).
- Test `packages/hub_core/test/still_clip_test.dart` runs the script on a generated picture and imports the result through the inbox watcher with the real `ffprobe`: a ready `hevc` 3840x2160 24 fps video of about 40 KB per 2 s. It skips itself without ffmpeg, ffprobe and a working bash.
- With the native 4K photo path (5-3) this mode is mostly a fallback; it needs nothing on the TV.
- Not verified on the TV: how the X90K shows the clip (it is the same profile as the 1-2 spike clips).
