---
title: 'TV spike app with DisplayReport and measurement script'
type: 'feature'
created: '2026-11-23'
status: 'done'
baseline_commit: 'NO_VCS'
route: 'dispatch'
review_loop_iteration: 1
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-fidelity.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every image-quality choice depends on what the Sony X90K really renders: an early adb reading shows the panel at 3840×2160 but a `wm size` override of 1920×1080, so the Flutter UI plane is probably 1080p. There is no project yet to install on the TV or to record that reading with.

**Approach:** Create the TV Saver Flutter project (TV flavor only in use), a bare full-screen TV app that shows and logs `DisplayReport`, and `tool/tv/display_report.sh`, which installs nothing, gathers `wm size`/`wm density`/`dumpsys display`/the app's log line into one report file. Kay runs it; the result is logged to the spec memlog.

## Boundaries & Constraints

**Always:**
- App name "TV Saver"; TV application id `com.codedbykay.tvsaver.tv`, phone `com.codedbykay.tvsaver` (Gradle product flavors `tv` and `phone`; only `tv` is built in this story).
- TV build is `android-arm` only (32-bit); strip other ABIs as drawing_poc does.
- Manifest: leanback launcher + banner so it appears on the Google TV home screen; immersive full screen.
- Release signing from day one: generate `android/app/upload-keystore.jks` + `android/key.properties` (random password), both git-ignored; tell Kay to back them up. Debug-key fallback with a warning, as in drawing_poc.
- `DisplayReport` copied (not depended on) from drawing_poc, logged at startup as `DisplayReport: renders …, panel …`.
- The report screen also shows the app version and is readable from the sofa (large text, high contrast).

**Never:**
- No networking, Pi, hub, player or phone app code (later stories).
- Nothing ever changes a setting on the TV (Kay's decision): the script is read-only (no `wm size`/`wm density`/`settings put` or similar writes), and no `--try-4k` experiment exists. The 1080p override is recorded as-is; story 5-3 (native 4K image path) stays required.
- No dependency on `../drawing_poc`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| 1080p override | render 1920×1080, panel 3840×2160 | screen + log: "below the panel" | N/A |
| Native 4K | render 3840×2160, panel 3840×2160 | "(4K)" | N/A |
| No view yet | no Flutter views | log "DisplayReport: unknown"; screen retries on first frame | no crash |
| Script, TV unreachable | `adb connect` fails | script exits non-zero with "TV not reachable at <ip>" | no partial report file |
| Script, app not running | no DisplayReport line in logcat | script launches the app, waits ≤ 15 s, then reports "app line missing" but keeps the adb sections | non-zero exit |

</frozen-after-approval>

## Code Map

- `../drawing_poc/lib/tv/display_report.dart` -- copy into `lib/tv/display_report.dart` and adapt: keep render size from the view's `physicalSize`, `summary`, `belowDisplay`, `isNative4k`; but the **panel size must NOT come from `view.display.size`** — on the X90K Android applies the `wm size` override to it (measured: app logged `panel 1920×1080 … (not 4K)` while the real panel is 3840×2160). Panel size comes from the native display mode: `Display.getMode().physicalWidth/physicalHeight` via a method channel in `MainActivity.kt` (e.g. `tvsaver/display`, method `panelSize`), passed into `DisplayReport`. If the channel fails, fall back to `view.display.size` and mark the summary `(panel unverified)`.
- `../drawing_poc/test/display_report_test.dart` -- copy, retarget package import, add the channel/fallback cases.
- `lib/tv/report_screen.dart` -- KEEP layout, injectable `read`/`log`, log-once behaviour; cap the null-view retry (≤ 10 post-frame retries, then stop and log once) and add a test where a size change makes `read` return a different report and a second log line + new on-screen numbers appear.
- `../drawing_poc/android/app/build.gradle.kts` -- reuse keystore loading, `android-arm` ABI stripping, `minSdk = max(flutter.minSdkVersion, 26)`; add flavors.
- `../drawing_poc/android/app/src/main/AndroidManifest.xml` -- reuse leanback/banner/launcher block only; drop camera, share, installer, deep-link entries.
- `../drawing_poc/android/app/src/main/res/drawable-*/tv_banner.png` -- reference only; draw a new "TV Saver" banner (320×180 xhdpi).
- `../drawing_poc/BUILD_AND_DEPLOY.md` -- keytool and build command patterns.
- Tools: Flutter 3.47.0; keytool at `C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe` (not on PATH); adb sees TV `192.168.0.24:5555` (BRAVIA_VH21) and a Pixel 9 Pro XL.

## Tasks & Acceptance

**Execution:**
- [x] `pubspec.yaml`, `analysis_options.yaml`, `android/**`, `.gitignore` -- `flutter create` (org `com.codedbykay`, name `tv_saver`), then flavors, signing, ABI stripping, manifest, banner -- project skeleton both apps will share.
- [x] `android/app/src/main/kotlin/com/codedbykay/tvsaver/MainActivity.kt` -- method channel returning the native display mode's physical width/height -- true panel size despite the `wm size` override.
- [x] `lib/main_tv.dart` -- immersive full-screen app logging and showing DisplayReport -- the spike app.
- [x] `lib/tv/display_report.dart` -- copied and adapted class (panel from the channel) -- measurement.
- [x] `lib/tv/report_screen.dart` -- report screen with capped retry -- sofa-readable output.
- [x] `test/display_report_test.dart`, `test/report_screen_test.dart` -- unit tests for the matrix rows (1080p render + 3840×2160 panel ⇒ "below the panel"), channel fallback, capped retry, re-read on size change -- regression.
- [x] `tool/tv/display_report.sh` -- connect, launch app, collect adb sections + logcat line into `build/measurements/display-report-<timestamp>.txt`, print the summary -- Kay's measurement.
- [x] `BUILD_AND_DEPLOY.md` -- build/install/measure commands and keystore backup note -- runbook.

**Acceptance Criteria:**
- Given the release TV APK, when installed with `adb install` on the X90K, then "TV Saver" appears on the Google TV home row and opens full screen.
- Given the app is running, when `tool/tv/display_report.sh 192.168.0.24:5555` runs, then the report file contains the DisplayReport line, `wm size`, `wm density`, display modes and HDR capabilities.
- Given `flutter analyze` and `flutter test`, when run, then both pass with no issues.

## Implementation Notes

- Android namespace / MainActivity package `com.codedbykay.tvsaver`; flavor `tv` adds `applicationIdSuffix ".tv"`. TV-only manifest entries (leanback launcher, banner, touchscreen/leanback not required) and black full-screen launch/normal themes live in `android/app/src/tv/` (values and values-night, since the TV runs in night mode).
- App version comes from `package_info_plus` (only added dependency). `ReportScreen` (`lib/tv/report_screen.dart`) takes injectable `read`/`log` for tests; it re-reads on view size change and logs each new reading once.
- Script: if the app is running but its line has rotated out of logcat, it `am force-stop`s and relaunches the app (no setting is touched). Logcat is filtered by the app's current pid.
- Dry run against the TV (app not installed): exit 2 "app line missing", adb sections present. `wm size`: physical 3840x2160, override 1920x1080; density 320; only one display mode exposed (3840x2160 @ 60 Hz, no 24 Hz mode); HDR types [1, 2, 3] (Dolby Vision, HDR10, HLG). The DisplayReport reading itself is still Kay's to record.

## Spec Change Log

- **Loop 1 (bad_spec).** Trigger: Blind Hunter "panel may repeat the render size"; verified on the X90K — app logged `renders 1920×1080, panel 1920×1080, ratio 2.00 (not 4K)` while `wm size` shows physical 3840×2160, violating the frozen matrix row "1080p override ⇒ below the panel". Amended: Code Map (panel size from `Display.getMode()` via a method channel, fallback marked "panel unverified"; report-screen retry cap and re-read test) and Tasks. Known-bad state avoided: the on-screen and logged verdict says "not 4K" instead of "below the panel", so Kay would record the wrong reading. KEEP: project skeleton, flavors and ids, `android/app/upload-keystore.jks` + `android/key.properties` (already signing the APK installed on the TV — never regenerate), TV manifest/banner/themes, `tool/tv/display_report.sh`, `BUILD_AND_DEPLOY.md`, `package_info_plus` version line, ReportScreen layout and injectable `read`/`log`.

## Review Triage Log

| # | Source | Finding | Verdict | Evidence / route |
|---|---|---|---|---|
| 1 | blind | Panel size from `view.display.size` repeats the override | high | Verified on TV: logged panel 1920×1080 vs physical 3840×2160 → bad_spec (loop 1) |
| 2 | blind + verif-gap | No test that a size change re-reads and re-logs | medium | Only resize test returns a constant `read` → patch (folded into loop 1 tasks) |
| 3 | blind + edge | Null-view retry is uncapped, redraws every frame | low | `_refresh` re-schedules `setState` while `read()` is null; trivial cap → patch (folded into loop 1) |
| 4 | edge | `physicalSize` 0×0 before layout logs "renders 0×0" | maybe-false | `didChangeDependencies` runs after the view is attached; would need a device trace → rejected (low if true) |
| 5 | edge | `view.display` may throw / be 0×0 | maybe-false | Superseded by #1 (panel no longer from `view.display` except as fallback) → rejected |
| 6 | edge + blind | `isNative4k` ignores height/panel | low | Real for 3840×1600 or 8K panels; X90K is 3840×2160 → rejected (unlikely) |
| 7 | edge | Script stops at a transient first line | low | App logs the first real reading once; transient 0×0 unproven → rejected |
| 8 | edge | `tv()` merges stderr into `pm path`/`pidof` | low | Android 12 prints nothing on miss; unlikely → rejected |
| 9 | edge | `pidof` returns several PIDs | low | Single-process app → rejected |
| 10 | edge + blind | adb drops mid-run → report of error text, exit 0 | low | Real but rare; needs guards → rejected |
| 11 | edge | `key.properties` missing a key → obscure NPE | low | Copied drawing_poc pattern; file is generated → rejected |
| 12 | edge | `FileInputStream` not closed | low | Gradle config, negligible → rejected |
| 13 | verif-gap + blind | Script exit-code contract untested, no shellcheck | medium | No shell test harness in repo; manual runs verified exits 0/1/2 → defer |
| 14 | blind | Reads `views.first` not `View.of(context)`; mode change without size change missed | low | X90K exposes one mode → rejected |
| 15 | blind | Release falls back to debug key silently | false | Spec Always requires the debug-key fallback with a warning |
| 16 | blind | USB serial gets `:5555` appended | low | TV is network adb only → rejected |
| 17 | blind | BUILD doc lacks IP/flavor guidance | low | Doc already shows `--flavor tv -t`; rejected |
| 18 | blind | `phone` flavor declared but not buildable | false | Spec: flavors `tv` and `phone`, only `tv` built in this story |
| 21 | verif-gap (loop 2) | No test that `TvSaverApp(panel:)` reaches the report | medium | Pre-verified: the only app test passes no panel; dropping the wiring keeps all tests green → patch |
| 22 | verif-gap (loop 2) | Kotlin `panelSize` contract only checked against a Dart mock | medium | Needs an instrumented test; on-device run 2026-11-23 confirmed `panel 3840×2160` with no "unverified" → defer |
| 23 | edge + blind (loop 2) | `fetchPanelSize` lets a `TypeError` escape on a non-map reply | low | Real for a malformed reply, but our Kotlin always replies with a map or an error; fix is an extra guard → rejected |
| 24 | edge (loop 2) | `main` awaits `panelSize` forever if never answered | low | Kotlin handler always calls `result`; unlikely → rejected |
| 25 | blind (loop 2) | `Display.getMode()` is the active mode, not the panel | low | X90K exposes one mode (3840×2160); verified on device → rejected |
| 26 | blind (loop 2) | Panel read once at startup | low | One display mode on this TV → rejected |
| 27 | edge (loop 2) | Retry counters not reset after a valid reading; no `didUpdateWidget` | low | View never disappears in this app; `read` is constant → rejected |
| 28 | edge + blind (loop 2) | `analysis_options.yaml` / Android files / `android/.gitignore` missing | false | All exist in the repo (`include: package:flutter_lints/flutter.yaml`, tracked `android/.gitignore`); they were outside the review diff's path list |
| 29 | blind (loop 2) | 32-bit-only depends on the `--target-platform` flag | low | Documented build command passes it → rejected |
| 30 | blind (loop 2) | Script force-stops on a "gave up" line; doc lacks debug-prompt/dev-loop notes | low | Rare and non-destructive (no setting change) → rejected |
| — | loop 2 carried | 0×0 render, fallback 0×0, `isNative4k`, `key.properties` keys, `FileInputStream`, adb drop, multi-PID, USB serial, `phone` flavor, script tests | carried | Same location and claim as rows 4, 5, 6, 11, 12, 10, 9, 16, 18, 13; code unchanged there |
| 19 | blind | Duplicate values/values-night styles | low | Intentional (night mode wins); rejected |
| 20 | blind | Comments mention a non-existent About screen | low | Cosmetic in copied class → rejected |

## Verification

**Commands:**
- `flutter analyze` -- expected: no issues
- `flutter test` -- expected: all pass
- `flutter build apk --release --flavor tv --target-platform android-arm -t lib/main_tv.dart` -- expected: APK built, < 25 MB

**Manual checks (if no CLI):**
- Kay: install on the TV, run the script, confirm the on-screen summary matches the report file.
