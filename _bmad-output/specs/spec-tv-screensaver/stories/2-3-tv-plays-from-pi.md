---
title: 'TV plays a hard-coded playlist from the Pi; throughput and power-cut tests'
type: 'feature'
created: '2026-11-23'
status: 'done'
baseline_commit: '52c219417852e003ca824ababfa82013b7965515'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/lan-setup.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The TV app only plays local clips; authenticated 4K Wi-Fi streaming from the Pi (CAP-2), sustained Pi → TV throughput for the 60 % ceiling (`media-server.md`), and unattended power-cut recovery with TV reconnect (CAP-11) are still unverified.

**Approach:** Add a **Pi stream & throughput** screen to the TV app that streams a hard-coded Pi playlist via Media3 `SurfaceView` with `Authorization: Bearer` headers (auto-reconnecting on outages) and runs an in-memory 1 GiB HTTP download benchmark logging Mbps and its 60 % ceiling. Ship PC scripts to stage clips + a 1 GiB file on the Pi, push `pi_config.json` to the TV app's files dir, and run Kay's power-cut test.

## Boundaries & Constraints

**Always:**
- Stream via Media3 `SurfaceView` (`tvsaver/media3view`) using `DefaultHttpDataSource` with `Authorization: Bearer <token>` header — never in URLs, logs, git, or APK.
- Add `INTERNET` permission and `usesCleartextTraffic="true"` in `AndroidManifest.xml` (LAN HTTP; release APKs lack Flutter's debug `INTERNET`).
- Push `pi_config.json` (`{host, port, token, playlist, throughputFile}`) into `/sdcard/Android/data/com.codedbykay.tvsaver.tv/files/pi_config.json` via `tool/pi/setup_phase2.sh` (reads token over SSH silently; never alters TV settings).
- 1 GiB throughput test streams `GET /media/<throughputFile>/full` with bearer auth via `dart:io` `HttpClient`, discarding bytes in memory (zero TV flash writes), showing live MB/s/Mbps and logging `PiThroughput: bytes=<N> seconds=<S> mbps=<M> ceiling_mbps=<C>` (`C = 0.60 * M`).
- Playlist loops (`REPEAT_MODE_ALL`, or `REPEAT_MODE_ONE` for 1 item), handles Left/Right (prev/next), OK (overlay), Back (stop), and polls `/health` every 3 s on outage to auto-resume (stops retrying on `401`).
- `tool/pi/power_cut_test.sh` verifies Floor 1 baseline + `/health`, prompts Kay to pull/restore Pi power, times `/health` recovery (pass ≤ 120 s), and checks Floor 1 Wi-Fi, `tvsaver` active, and Avahi `_tvsaver._tcp`.
- Keep `DisplayReport` (1-1) and `SpikeScreen` (1-2) working and read-only on TV settings.

**Never:**
- No pairing, WebSocket, TV mDNS, DB, uploads, TV cache, or phone app changes; no writing 1 GiB to TV flash; no TV setting changes; no sudo from PC scripts.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Missing/bad config | Absent or invalid `pi_config.json` | Shows error + `setup_phase2.sh` hint | No crash; token never shown |
| Stream playlist | Valid config, Pi online | Media3 SurfaceView streams with `Bearer`, loops clips | Overlay: clip, decoder, HDR, dropped, pos |
| Auth failure | HTTP `401` | Shows `auth failed (401)`, halts retry | Hint to re-run `setup_phase2.sh` |
| Pi outage / power cut | Pi drops before/mid-stream | Shows `Reconnecting…`, polls `/health` every 3 s, resumes on `200` | Logs `PiStream: disconnected` / `reconnected` |
| Throughput test | OK on throughput row | Streams 1 GiB to memory, shows & logs `PiThroughput:` Mbps + 60 % ceiling | Back cancels cleanly |
| Throughput error | `401`, drop, or short body (`bytes < Content-Length`) | Shows reason; no bogus ceiling | `HttpClient.close(force: true)` |
| Power-cut script | Power pulled & restored | Times restore → `/health` 200 (≤ 120 s); verifies Floor 1 + `tvsaver` + Avahi | Explicit FAIL on timeout or Floor 2 |

</frozen-after-approval>

## Code Map

- `android/app/src/main/AndroidManifest.xml` -- add `INTERNET` and `usesCleartextTraffic="true"`.
- `android/app/src/main/kotlin/com/codedbykay/tvsaver/VideoSpike.kt` -- add `filesDir`, `m3OpenHttp {urls, headers}` (`DefaultHttpDataSource.Factory` + `DefaultMediaSourceFactory`), `m3Control` `next`/`prev`, and `durationMs`/`httpStatus` in `m3Stats()`. Keep 1-2 methods intact.
- `lib/tv/video_spike/spike_native.dart` -- keep `videoChannel`/`media3ViewType`; add HTTP/`filesDir` on a separate `PiVideoNative` wrapper so `video_spike_test.dart` stays green.
- `lib/main_tv.dart` -- home launcher: `OK: Pi stream` → `PiScreen`, `Right: video spike` → `SpikeScreen`.
- `lib/tv/pi/pi_config.dart`, `throughput_runner.dart` -- config parser/loader (no token in URLs) and streaming HTTP benchmark (`PiThroughput:` formatter).
- `lib/tv/pi/pi_player.dart`, `pi_screen.dart` -- Media3 SurfaceView player (overlay, Left/Right, `/health` reconnect, `PiStream:` logs) and remote menu + live throughput progress.
- `tool/pi/setup_phase2.sh`, `tool/pi/power_cut_test.sh`, `BUILD_AND_DEPLOY.md` -- staging (`build/spike-media/[1-5]-*.mp4` + sparse 1 GiB `throughput-1g.bin`, ADB `pi_config.json`), power-cut script, Section 11 runbook.

## Tasks & Acceptance

**Execution:**
- [x] `android/app/src/main/AndroidManifest.xml`, `VideoSpike.kt` -- LAN HTTP + `m3OpenHttp`/next/prev/`httpStatus` -- authenticated 4K SurfaceView streaming.
- [x] `lib/tv/pi/pi_config.dart`, `throughput_runner.dart` -- config loader + in-memory 1 GiB benchmark -- core logic.
- [x] `lib/tv/pi/pi_player.dart`, `pi_screen.dart`, `lib/main_tv.dart` -- TV player with auto-reconnect, throughput UI, launcher -- TV UX.
- [x] `test/pi_stream_test.dart`, `test/video_spike_test.dart` -- loopback HTTP unit/widget tests for all matrix rows + updated launcher test -- regression.
- [x] `tool/pi/setup_phase2.sh`, `tool/pi/power_cut_test.sh`, `BUILD_AND_DEPLOY.md` -- PC scripts + Section 11 runbook -- tooling & docs.

**Acceptance Criteria:**
- Given `flutter analyze`, `flutter test`, `bash -n tool/pi/*.sh`, and TV release APK build (`--flavor tv --target-platform android-arm`), when run, then all pass and APK < 25 MB.
- Given `setup_phase2.sh` ran, when Kay plays the Pi playlist on the X90K, then clips stream smoothly with bearer auth (HDR10/HLG intact) and Left/Right switch clips.
- Given Kay runs the 1 GB throughput test on the X90K, when done, then `PiThroughput:` logs Mbps and 60 % ceiling with zero flash writes, recorded in `.memlog.md`.
- Given the TV is playing and Kay runs `power_cut_test.sh`, when Pi power returns, then Pi rejoins Floor 1, `/health` answers ≤ 2 min, Avahi lists `_tvsaver._tcp`, and TV auto-resumes.

## Implementation Notes

- Verified on the X90K and gemini-pi (2026-11-23/24): the 5-clip Pi playlist streams with bearer auth; 1 GiB throughput test measured 134.58 Mbps (63.83 s, 0 flash writes), 60 % ceiling 80.75 Mbps; `power_cut_test.sh` passed 8/8 with `/health` back in 12 s on Floor 1.
- Not verified on hardware: the TV's "Reconnecting…" and auto-resume. The playlist kept playing through the short outage because ExoPlayer's buffer covered it. Covered by the loopback widget test; Kay chose to proceed and fix later if needed (retest: clip 5, Pi off for 2+ minutes).
- `flutter analyze` clean, `flutter test` 52/52, `hub_core` 19/19, TV release APK 13.1 MB.
- Test fix: loopback widget tests must bind and wait on real sockets through `tester.runAsync` and a `_pumpUntil` helper; awaiting root-zone futures inside `testWidgets` hung forever.

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `flutter analyze` and `flutter test` -- expected: no issues, all pass
- `flutter build apk --release --flavor tv --target-platform android-arm -t lib/main_tv.dart` -- expected: succeeds, APK < 25 MB
- `bash -n tool/pi/setup_phase2.sh tool/pi/power_cut_test.sh` -- expected: no syntax errors

**Manual checks (if no CLI):**
- Kay installs the TV APK, runs `setup_phase2.sh`, tests Pi playlist + 1 GB throughput on the X90K, runs `power_cut_test.sh`, and shares outputs for `.memlog.md`.
