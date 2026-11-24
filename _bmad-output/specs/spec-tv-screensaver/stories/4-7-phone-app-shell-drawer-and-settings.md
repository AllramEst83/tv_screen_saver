---
title: 'Phone app shell: drawer, grouped settings and idle TV screen'
type: 'feature'
created: '2026-11-24'
status: 'in-review'
baseline_commit: '39cb81d4d37fcc5d081454d046b367d21ce38452'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The phone app is one plain screen. There is no navigation, no place to change how the system behaves (storage cap, streaming ceiling, photo duration), every phone is called "Phone", and the TV shows an empty black screen when nothing is playing.

**Approach:** Give the phone app a proper shell: a navigation drawer with a Close app button, a Settings page whose options are grouped in panes, readable names for phones, and a persistent Pi `settings` module behind it. Give the TV a calm, good-looking idle screen. Library and playlist screens (4-3, 4-4) plug into the same drawer later.

## Boundaries & Constraints

**Always:**
- **Drawer:** header with the Pi's name, a connection status line ("Connected", "Reconnecting…", "TV off") and this phone's role. Entries: Now playing, Devices, Settings, About, a divider, then **Close app**. Only built screens appear; 4-3 and 4-4 add Library and Playlists through the same destination list. Close app releases the multicast lock, disconnects the client and calls `SystemNavigator.pop()`.
- **Settings page:** one scrolling page, each pane a titled card with a one-line explanation per option and plain labels (no jargon, units shown). Panes: **Playback** (photo duration 3–120 s, transition crossfade or cut, Ken Burns, play with sound); **Library and storage** (used of cap with a progress bar, storage cap in GB); **Network and streaming** (streaming ceiling in Mbps, TV cache size in GB, short "why this matters" text); **Devices and pairing** (this phone's name, paired devices with online state, Forget all phones for the owner); **About** (app version, Pi name, id and version, TV connected or not). Everyone can read every setting; only the owner can change them, and a controller sees the controls disabled with "Only the owner can change this". A saved change shows a brief confirmation; a rejected value shows the reason next to the field.
- **Pi `settings` module:** persisted in a drift `Settings` table (schema 4, `onUpgrade` keeps all data). Keys: `imageSeconds` (10), `transition` (`crossfade`|`cut`), `kenBurns` (false), `playWithSound` (true), `storageCapBytes`, `streamingCeilingMbps`, `tvCacheBytes`. First values come from the existing environment settings. `settings.update {…}` (owner or display, validated ranges, partial updates), snapshot `{values, limits}`, event `settings.changed {values}`. Live consumers read the stored value: the library storage cap and the media worker's ceiling and cache cap change without a restart.
- **Phone names:** a new phone connects with its device model (e.g. "Pixel 9 Pro XL") and the user can rename it from Settings or the Devices screen (`device.rename`). Names are trimmed and limited to 40 characters.
- **Devices screen:** same list as the Devices pane with larger rows; the owner can remove a phone (`device.forget`) after a confirm.
- **Now playing (home):** keep the current controls, restyled as a hero card with item name, a progress bar, large prev/play-pause/next buttons and a clear "TV not connected" state. A global status banner appears under the app bar when the Pi is offline or reconnecting.
- **Look and feel:** Material 3, follows the system light or dark mode, large touch targets (≥ 48 dp), consistent spacing, smooth transitions, accessible labels, no horizontal scrolling at 360 dp, readable at 200 % font scale.
- **TV idle screen** (nothing playing, paired): near-black background, large soft clock and date centred, one status line ("Ready — choose something on your phone"), a small Pi status dot. The whole group drifts slowly to a new position every minute (no static image, no strobing). When no phone is paired the existing pairing view stays in charge. It disappears the moment playback starts. The TV remote Menu key still works.
- No mention of Drawing Aid or drawing_poc anywhere.

**Never:**
- No library, upload or playlist screens, no TV settings screen, no new TV system settings, no iOS, no accounts or logins.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Open drawer | Menu button or edge swipe | Header status, destinations, Close app | — |
| Close app | Tap Close app | Lock released, client disconnected, app exits | — |
| Owner edits a setting | Changes ceiling to 60 | Saved on the Pi, `settings.changed`, other phones update | Out of range → message, value reverted |
| Controller views settings | Role controller | All panes readable, controls disabled with the owner note | `settings.update` returns `forbidden` |
| Storage cap lowered below usage | Cap < used | Saved; new uploads get `507 full`, nothing deleted | Pane shows "over the limit" |
| Pi offline | Connection lost | Banner "Reconnecting…", settings read-only, last values shown | — |
| Rename phone | Valid or empty or > 40 chars | Saved; empty or too long refused | Message under the field |
| Pi restart | Settings stored | Values survive the restart | — |
| Idle TV | Paired, nothing playing | Clock screen drifting each minute | Playback start replaces it at once |
| Upgrade | Pi database at version 3 | Data kept, `Settings` added with defaults | — |

</frozen-after-approval>

## Code Map

- `packages/hub_core/lib/src/db/hub_database.dart` -- `Settings` table, `schemaVersion` 3 → 4, `onUpgrade`; regenerate `hub_database.g.dart`.
- `packages/hub_core/lib/src/server/settings_module.dart` (new, follow `DevicesModule`/`PlayerModule`), `settings_store.dart` (new, typed values, validation, change notifications); `server.dart` registers it and feeds `LibraryStore` (storage cap) and `MediaWorker` (ceiling, cache cap) from the store; `config.dart` provides initial values; `lib/hub_core.dart` exports.
- `lib/phone/phone_controller.dart` -- settings snapshot/events, rename, forget, close; `lib/phone/screens/` -- new `app_shell.dart` (Scaffold + drawer + status banner), `settings_screen.dart`, `devices_screen.dart`, `about_screen.dart`; restyle `home_screen.dart` and `now_playing_card.dart`; `lib/main_phone.dart` -- wire the shell and device-model name (`device_info_plus`).
- `lib/tv/display/display_screen.dart` (idle state), new `lib/tv/display/idle_view.dart`; keep `pairing_view.dart`.
- `android/` -- nothing unless a plugin needs permissions; `pubspec.yaml` -- `device_info_plus`.
- Tests: `packages/hub_core/test/` (settings module, persistence across restart, live consumers, migration from a real version 3 file), `test/phone/` (drawer, settings panes, role gating, close app via a mocked `SystemNavigator.pop` channel, rename), `test/tv/` (idle view, drift timer with fake time).
- `modules.md` (settings snapshot and event), `BUILD_AND_DEPLOY.md` (settings and where they live).

## Tasks & Acceptance

**Execution:**
- [ ] `hub_database.dart` + `.g.dart`, `settings_store.dart`, `settings_module.dart`, `server.dart`, `config.dart` -- persistent settings and live consumers
- [ ] `phone_controller.dart` -- settings, rename, forget, close, default device-model name
- [ ] `app_shell.dart`, `settings_screen.dart`, `devices_screen.dart`, `about_screen.dart`, `home_screen.dart`, `now_playing_card.dart`, `main_phone.dart` -- drawer, panes, banner, hero card
- [ ] `idle_view.dart`, `display_screen.dart` -- idle TV screen
- [ ] tests and docs as listed

**Acceptance Criteria:**
- Given `flutter analyze`, `flutter test`, hub_core `dart analyze` and `dart test`, then all pass and both release APKs and the arm64 exe build.
- Given two phones, when the owner changes the streaming ceiling, then the second phone shows the new value without a refresh and it survives a Pi restart; the controller's controls are disabled with the owner note.
- Given the TV is paired and idle, when a minute passes, then the clock group has moved; when a clip starts, the idle screen is gone.

## Implementation Notes

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence |
| --- | --- | --- | --- |
| Phone keeps settings, item names and storage figures of a previous Pi; settings stay editable when the snapshot lacks the module | medium | patch | `_readSettings`/`_readLibrary` only overwrite when present |
| Storage used-bytes derived on the phone drifts (unfinished uploads, updates never counted); "0 of 0" when cap missing; no phone-side test | medium | patch | `_noteItem`; Pi has the true figure |
| Stored or environment values outside the limits are applied on load; infinite number crashes `_validate`; a failed write surfaces as a generic error | medium | patch | `SettingsStore.load`, `_validate`, `update` |
| Number field saves twice (submit and focus loss), typed text lost when disabled or unmounted; overlapping saves flicker | medium | patch | `_NumberFieldState._commit`, `_save` |
| Streaming limit change does not recompute `cacheRequired`, yet the pane promises it | medium | patch | Notes in BUILD_AND_DEPLOY.md; recompute on `settings.changed` |
| Close app: double tap, `_closing` not reset on resume when not paired, reconnect after resume untested | medium | patch | `closeApp`, `setForeground` |
| Phone removed by the owner or "Forget all phones": what it sees is untested; appNotOpen shown as "Can't reach the Pi" | medium | patch | Only the other phone's row is asserted |
| Device name: model code on some phones (e.g. SM-S918B), no timeout on `androidInfo`, 40-char cut can split a surrogate pair, hello name cut untested | low | patch | `_deviceName`, `hub_server.dart` hello |
| Idle TV: clock hard-coded 24 h English, clock jump after NTP sync, link mapping (connected/connecting/unreachable) only tested at the leaf | medium | patch | `idle_view.dart`, `_idleView` |
| About "Pi software" prints the protocol number; Forget dialog shows a CLI command; owner note only at the top of the page | low | patch | `about_screen.dart`, settings dialogs |
| Test gaps: storage pane via `LibraryModule`, cap lowering through `settings.update` (test writes the config directly), vacuous `anyOf` in the rename test, hello-name truncation | medium | patch | Verification-gap evidence |
| `t`/`rid`/`op` keys dropped instead of refused; `hub_server.dart` imports `devices_module.dart` for a constant; import order | low | reject | Framing keys, lint clean, no named harm |
| Close during an upload; no re-check-library action | low | reject | No uploads until 4-3 |
| Story file status and notes empty | false | reject | Workflow updates the story after review |

## Verification

**Commands:**
- `flutter analyze && flutter test` and `cd packages/hub_core && dart run build_runner build --delete-conflicting-outputs && dart analyze && dart test` -- expected: no issues, all pass
- `flutter build apk --release --flavor tv -t lib/main_tv.dart --target-platform android-arm`, `flutter build apk --release --flavor phone -t lib/main_phone.dart` and the arm64 `dart compile exe` -- expected: success

**Manual checks (batched with the final checklist):**
- Kay opens the drawer, changes settings as owner and as a second phone, closes the app, and looks at the idle TV screen.
