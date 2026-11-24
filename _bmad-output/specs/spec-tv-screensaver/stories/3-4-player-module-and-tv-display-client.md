---
title: 'Player module and TV display client'
type: 'feature'
created: '2026-11-24'
status: 'in-progress'
baseline_commit: '2bd69168ef6f52f5d1b37603420466ebb377812e'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi pairs a phone and a display (3-2, 3-3), but nothing plays. The TV app still streams a hard-coded playlist with a static token, shows no pairing QR, and neither the phone nor the TV remote can control playback (CAP-6, CAP-7).

**Approach:** Add a `player` and a `display` module to the Pi hub, and turn the TV app into the paired display client that renders the pairing QR and plays what the Pi tells it. Wire phone controls and TV remote keys to `player.*`.

## Boundaries & Constraints

**Always:**
- Pi: `player.play {playlistId, index?}`, `next`, `prev`, `pause`, `resume`, `seek {positionMs}`, `setMuted {muted}`; display-only `player.position {itemId, positionMs, at}` (every 10 s and on change; updates the snapshot, no `rev` bump) and `player.report {…}` on every (re)connect (adopted, emits `player.changed`); `display.capabilities {decoders[], hdr[], render, panel}` on every connect, stored per display id in memory. Names and fields as in `modules.md`.
- Every command updates state, emits `player.changed {playlistId, index, itemId, state, positionMs, startedAt, muted}`, and sends the display a targeted `display.load {itemId, variant:"full", startAt}` for item changes or `display.control {action: pause|resume|seek|mute, positionMs?, muted?}` otherwise. With no display connected, phone and remote `player.*` get `err {code: unavailable}`. Player state is keyed by display id.
- Until story 4-4 there is one playlist, id `all`: the files in the Pi media directory, sorted by name, behind a `PlaylistSource` interface the playlist module replaces later. Item ids are the existing media ids.
- TV: connects to the Pi as a display (`hello {kind:"display"}`, token in secure storage), discovery by last address then mDNS, auto-reconnect. While no phone is paired, or when `display.pairing` arrives, it shows the pairing screen: QR plus PIN. It sends capabilities and reports on connect. It streams `/media/<id>/full` through the existing Media3 `SurfaceView` with `Authorization: Bearer <device token>`.
- TV remote: OK pause/resume, Left/Right prev/next, FF/RW seek ±30 s, hold Back 10 s sends `devices.forgetAll`. They go over the TV's socket as `player.*`, like a phone. If the Pi is unreachable the TV keeps looping the item it has and reconnects (full offline mode is 5-2).
- Phone Home: Play (playlist `all`), prev, play/pause, next, seek ±30 s, mute, now playing with position from `startedAt`; "TV not connected" on `unavailable`.
- Keep `DisplayReport` and the 1-2 and 2-3 screens reachable (Menu key), read-only on TV settings.
- No mention of Drawing Aid or drawing_poc anywhere.

**Never:**
- No library, upload or playlist editing, no cache or prefetch, no crossfade or Ken Burns, no TV setting changes, no removal of the Pi's static media token.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Play from phone | Display ready, `player.play {playlistId:"all"}` | `player.changed` to all; TV loads item 0 within 1 s | Unknown playlist → `err not_found` |
| Remote next | TV remote Right | Same as phone `player.next`; phones update | — |
| No display | Display offline, phone `player.next` | `err unavailable` | Phone shows "TV not connected" |
| Pause, seek, mute | Matching `player.*` | State and `display.control` follow; second phone shows same position | `seek` past end clamps |
| Item ends | Last item | Wraps to index 0, `player.changed` | Empty playlist → `err not_found` |
| TV reconnect | TV sends `player.report` | Pi adopts, emits `player.changed`, no restart of playback | Stale report for removed item ignored |
| Pairing | No phone paired / `display.pairing` | TV shows QR + PIN; phone scan pairs | Expired code refreshes |
| Forget all | Hold Back 10 s | `devices.forgetAll`; TV returns to pairing screen | — |

</frozen-after-approval>

## Code Map

- `packages/hub_core/lib/src/server/` -- add `player_module.dart`, `display_module.dart`, `playlist_source.dart` (media-dir `all` playlist); follow `DevicesModule` (`HubModule`, `HubHandlerSpec`, `HubOutboundEvent.targeted`/`broadcast`). `hub_server.dart`: display-only handlers (`requireDisplay`), capture of display id from the socket device, per-display state. `server.dart`: register modules. `lib/hub_core.dart` exports.
- `packages/hub_core/lib/src/hub_client.dart` -- add `kind` (phone|display) to the hello so the TV can use `HubClient`; keep phone behaviour.
- `lib/tv/display/` -- new: display client (wraps `HubClient`, secure token store reuse from `lib/phone/secure_token_store.dart` moved to shared code), pairing screen (QR via `qr`), player bridge to Media3; `lib/main_tv.dart` home becomes the display screen, Menu opens `ReportScreen`/spikes.
- `lib/tv/video_spike/spike_native.dart`, `android/app/src/main/kotlin/com/codedbykay/tvsaver/VideoSpike.kt` -- `m3OpenHttp`, `m3Control` (`next`/`prev`); add pause, resume, seek, mute, item-ended callback; keep 1-2/2-3 working. `lib/tv/pi/` -- reuse the HTTP auth and reconnect parts; static `pi_config.json` no longer needed by the display client.
- `lib/phone/phone_controller.dart`, `lib/phone/screens/home_screen.dart` -- player controls and now playing from the `player` snapshot/events.
- `test/`, `packages/hub_core/test/` -- hub module tests with the fake display harness; Flutter tests with a fake native channel and fake hub.
- `_bmad-output/specs/spec-tv-screensaver/modules.md` -- add `display.control`; `BUILD_AND_DEPLOY.md` -- TV pairing and phone control steps.

## Tasks & Acceptance

**Execution:**
- [ ] `hub_core` -- `PlaylistSource`, `player` and `display` modules, registration, `HubClient` display kind
- [ ] `hub_core/test` -- every matrix row at module level (fake display, two phones, no display)
- [ ] Android native -- pause/resume/seek/mute and item-ended in the Media3 channel
- [ ] `lib/tv/display/`, `lib/main_tv.dart` -- display client, pairing screen, player bridge, remote keys
- [ ] `lib/phone/` -- controls, now playing, unavailable state
- [ ] Flutter tests for TV client and phone controls; docs

**Acceptance Criteria:**
- Given `flutter analyze`, `flutter test`, hub_core `dart analyze` and `dart test`, then all pass and both release APKs build.
- Given a fresh TV, Pi and phone, when the TV app starts, then it shows a QR the phone scans to pair as owner; Play on the phone starts the first clip within 1 s; the remote's Right key and the phone's Next both advance and both show the same item and position.
- Given the Pi restarts mid-play, when it returns, then the TV reconnects, reports its position and the picture does not restart.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `flutter analyze && flutter test` -- expected: no issues, all tests pass
- `cd packages/hub_core && dart analyze && dart test` -- expected: all pass
- `flutter build apk --release --flavor tv -t lib/main_tv.dart --target-platform android-arm` and `flutter build apk --release --flavor phone -t lib/main_phone.dart` -- expected: success

**Manual checks:**
- Kay deploys the Pi server, starts the TV app, scans its QR, plays from the phone and the remote, restarts the Pi once.
