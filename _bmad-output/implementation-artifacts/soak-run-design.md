---
title: 'Always-on playback — wakelock, immersive mode, 8 h run'
type: 'feature'
created: '2026-11-23'
status: 'draft'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/lan-setup.md'
  - '{project-root}/BUILD_AND_DEPLOY.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** CAP-1 (the TV plays indefinitely without screensaver, Ambient Mode or standby, and without leaking memory) is untested. The app holds no wakelock, and nothing records what interrupts playback or how memory behaves over hours.

**Approach:** Add a "Soak run" to the TV app: a muted 4K video looping through the proven Media3 repeat-one path with `wakelock_plus` held and immersive mode re-applied, plus an in-app recorder that logs memory and every lifecycle interruption to a CSV on the TV. Ship a read-only PC script to sample `dumpsys` independently and a report script that judges the trend. Kay applies the TV settings by hand and runs the 8 h test.

## Boundaries & Constraints

**Always:**
- Nothing ever changes a setting on the TV: tools only install, launch and read (`dumpsys`, `logcat`, `pull` of the app's own files). Kay switches Idle TV standby Off, Picture power saving Off and the longest screensaver delay by hand, per `lan-setup.md`.
- The soak plays clip `5-loop-audio.mp4` (already on the TV) via the Media3 SurfaceView, repeat-one, **muted by default** (a `--dart-define`-free in-app toggle may unmute); wakelock held only while the soak plays and released on stop.
- The recorder writes a header + one CSV row every 5 min and one row per lifecycle event (`resumed`, `inactive`, `paused`, `detached`, plus Media3 error/stall), to `files/soak/soak-<start>.csv` in the app's external files dir. Columns: ISO time, elapsed s, event, PSS KB, Java heap KB, native heap KB, dropped frames, player state, wakelock held.
- `tool/tv/soak_sample.sh` samples hourly from the PC (`dumpsys meminfo <pkg>`, `dumpsys power` wakefulness, `dumpsys window` focus, process alive) into `build/measurements/soak-<start>.txt`, read-only; it keeps going if one sample fails and exits when stopped.
- `tool/tv/soak_report.sh <csv>` prints: duration, interruptions (any `paused`/`detached`/error event, with times), PSS first-hour mean vs last-hour mean, linear slope in MB/h. **Pass** = no interruption, PSS slope < 10 MB/h and last-hour mean − first-hour mean < 100 MB.

**Never:**
- No Pi, network, hub, library or playlist code; no change to the spike's other screens beyond adding the entry row.
- The app never changes a system or TV setting; no `settings put`, no `wm`, no power commands.
- No auto-start on boot, no launcher takeover (the user starts it from the remote).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Normal soak | start soak, 8 h | video loops muted; CSV gets a row every 5 min; screen stays on | N/A |
| Interrupted | TV standby, screensaver or Ambient Mode starts | CSV gets `paused`/`inactive` row with time; on return the soak resumes playback and logs `resumed` | player error → `error` row, restart of playback, soak continues |
| Back pressed | user stops | wakelock released, CSV row `stopped`, file closed | N/A |
| Clip missing | `5-loop-audio.mp4` not on the TV | screen shows the adb push command | no crash, no empty CSV |
| Report on a short run | CSV < 2 h | report prints "not enough data for a trend (need ≥ 2 h)" | exit non-zero |
| Sampler loses the TV | adb drops mid-run | row `sample failed: <reason>`, retry next hour | script keeps running |

</frozen-after-approval>

## Code Map

- `lib/main_tv.dart`, `lib/tv/video_spike/spike_screen.dart` -- spike list; add a "Soak run" entry row. Immersive is set once in `main()` (`SystemUiMode.immersiveSticky`); re-apply it on resume.
- `lib/tv/video_spike/spike_player.dart`, `android/.../VideoSpike.kt` (`m3Open`, `m3Stats`, channel `tvsaver/video`) -- reuse the Media3 repeat-one path and its stats (`droppedFrames`, `error`); add a memory-info call (`Debug.getMemoryInfo`) to the channel.
- `pubspec.yaml` -- add `wakelock_plus` (^1.8.2, as in drawing_poc); on Android it sets the window keep-screen-on flag, no permission needed.
- `tool/tv/display_report.sh`, `tool/video/push_clips.sh` -- patterns for read-only adb scripts under Git Bash (`MSYS_NO_PATHCONV=1`, `cygpath -m`).
- `BUILD_AND_DEPLOY.md` -- add a soak runbook: the exact TV settings Kay applies by hand, start/stop, sampling, pulling the CSV, running the report, and a 1 h dry run first.
- Facts: the TV exposes one display mode (3840×2160 @ 60 Hz), the app renders 1920×1080, ~880 MB free storage, SDK 31, armeabi-v7a only.

## Tasks & Acceptance

**Execution:**
- [ ] `pubspec.yaml` -- add wakelock_plus -- keep the screen on.
- [ ] `lib/tv/soak/**` -- soak screen, recorder (CSV, lifecycle observer, 5-min timer), wakelock hold/release, immersive re-apply -- the 8 h run.
- [ ] `android/app/src/main/kotlin/**` -- memory-info channel method -- PSS/heap numbers.
- [ ] `lib/tv/video_spike/spike_screen.dart` -- "Soak run" entry row -- reachable from the remote.
- [ ] `tool/tv/soak_sample.sh`, `tool/tv/soak_report.sh` -- PC sampling and trend report -- measurement.
- [ ] `test/soak_test.dart` -- recorder rows/events, CSV format, wakelock held/released, missing clip screen, report script maths on a sample CSV -- regression.
- [ ] `BUILD_AND_DEPLOY.md` -- soak runbook incl. TV settings checklist -- Kay's procedure.

**Acceptance Criteria:**
- Given the soak is started from the remote, when it plays, then the log/CSV shows wakelock held and rows every 5 min.
- Given a pulled CSV from a 2 h dry run, when `soak_report.sh` runs, then it prints duration, interruptions, first/last-hour PSS and slope.
- Given Kay's 8 h run with the TV settings applied, when the report runs, then it shows no interruption and meets the pass thresholds (recorded in the memlog by Kay or me).
- `flutter analyze` and `flutter test` pass; the release APK builds.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Design Notes

An interruption row is the evidence that the TV settings are wrong or insufficient (Idle TV standby, Ambient Mode). If the 8 h run shows one, CAP-1's settings in `lan-setup.md` need a decision from Kay; this story records the outcome.

## Verification

**Commands:**
- `flutter analyze` -- expected: no issues
- `flutter test` -- expected: all pass
- `flutter build apk --release --flavor tv --target-platform android-arm -t lib/main_tv.dart` -- expected: APK built, < 25 MB
- `bash tool/tv/soak_report.sh <sample.csv>` -- expected: the report on the test fixture

**Manual checks (if no CLI):**
- Kay: apply the TV settings, install, run a 1 h dry run, then the 8 h soak; run the sampler and the report.
