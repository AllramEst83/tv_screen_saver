---
title: '8-hour soak on the X90K'
type: 'feature'
created: '2026-11-24'
status: 'in-review'
baseline_commit: '41cf0a1'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** CAP-1 (the TV plays for hours without a screensaver, standby or a memory leak) is untested on the full system.

**Approach:** Kay runs the 8 hours. This story prepares everything else: media and playlist, an independent PC sampler, the app's own playback log and a report that says PASS or FAIL. Status stays `in-review` until Kay has run it; the verdict goes in the memlog.

## Implementation Notes

- `tool/tv/soak_sample.sh` (read-only adb: `dumpsys meminfo/power/window`, `pidof`; one tab-separated line per sample, a failed sample never stops the run), `tool/tv/soak_report.sh` (duration, interruptions, first and last hour PSS, trend by least squares, PASS below 10 MB/h and under 100 MB growth, at least 2 h of data), `tool/tv/test/test_soak_scripts.sh` (29 checks with a fake adb).
- `tool/video/generate_photos.sh` (5 photos incl. the 1 px chart), `tool/soak/prepare_soak.sh` (clips and photos to the Pi with the resumable uploader), runbook in BUILD_AND_DEPLOY.md section 16.
- App: `PlaybackLog` (`playback_log.dart`, CSV in the app's external files directory, rolls over at 512 KB) written by `DisplayScreen`: start/stop, lifecycle, each new item, a heartbeat every 5 minutes.
- Differences from the 2026-11-23 draft (`soak-run-design.md`): the soak runs the real app and its playlist, not a spike screen; the wake lock and the full-screen re-apply already exist (5-1); the in-app memory numbers are replaced by the PC sampler's `dumpsys meminfo`.
- Not run: the soak itself (8 h, TV, Kay). The photo generator was run here and makes valid JPEGs; the upload and sampler were tested against fakes only.
