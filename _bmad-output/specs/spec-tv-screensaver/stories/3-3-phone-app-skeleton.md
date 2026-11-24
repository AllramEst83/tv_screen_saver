---
title: 'Phone app skeleton with discovery and QR pairing'
type: 'feature'
created: '2026-11-24'
status: 'in-progress'
baseline_commit: '2e5d4fe4ffafa74d87f128cd222fec39d3f940c4'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi can pair devices (3-2), but there is no phone app. Nobody can scan a QR code, hold a pairing, or find the Pi again after an IP change (CAP-7), and there is no TV QR yet to test against.

**Approach:** Build the `phone` flavor of the Flutter app (`com.codedbykay.tvsaver`, `lib/main_phone.dart`) on `hub_core`'s `HubClient`: QR scan pairing, PIN fallback, automatic reconnect (last address, then mDNS), and a connected screen showing role and paired devices. Add a dev "fake display" tool that stands in for the TV so pairing can be tried on a real phone.

## Boundaries & Constraints

**Always:**
- `hub_core` is a path dependency; all connection logic stays in `HubClient`/`HubScanner`. Pairing record (token, last host/port) is stored in `flutter_secure_storage` through a `HubTokenStore` implementation in the phone code.
- Android only. Hold the Wi-Fi multicast lock (native `MethodChannel`, reference counted) while scanning/reconnecting; add `CAMERA`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` to the phone flavor only where possible.
- Screens: Connect (status text per `HubConnectionPhase`, Scan QR, retry), Scan (camera, one-shot), PIN entry (when the Pi asks), Home (Pi name, own role, paired devices from the `devices` snapshot, online dots, "Forget this Pi" removing only the local pairing).
- App starts by trying `reconnectSavedHub()` when a pairing exists; a revoked token returns to Connect with a message.
- The TV flavor APK must not grow by more than 8 MB (measure release `--target-platform android-arm` before and after; use unbundled ML Kit for the scanner if needed). Report the numbers.
- `packages/hub_core/tool/fake_display.dart`: connects as a display (`hello {kind:"display"}`), calls `devices.startPairing`, prints the `tvsaver://pair?...` URI, an ASCII QR (`qr` package) and the PIN, refreshes on every `display.pairing`.
- No mention of Drawing Aid or drawing_poc in code, tests or docs.

**Never:**
- No TV app changes (other than shared `pubspec.yaml`/manifest edits needed to build), no library, playlist or player UI, no iOS, no uploads, no change to `hub_core` wire protocol.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| First launch | No saved pairing | Connect screen with Scan QR | — |
| Scan valid QR | Pi has an open pairing session | Pairs, Home shows role (first phone `owner`) and device list | — |
| Scan other QR | Not `tvsaver://pair` | "That isn't a TV Saver QR code." | Stays on Scan |
| Wrong/expired code | Code reused or expired | PIN entry appears | 3 wrong tries → lockout message with countdown |
| Relaunch | Saved pairing | Auto-reconnects, Home | Pi down → "TV not found" with Retry |
| Pi IP changed | Saved host stale | Reconnects via mDNS, saved host updated | — |
| Forgotten phone | Owner/TV sent forget all | Back to Connect with message | — |
| Camera denied | Permission refused | Message and Open settings | — |
| No session open | Pi has no pairing session | "Start pairing on the TV" message | — |

</frozen-after-approval>

## Code Map

- `pubspec.yaml` -- add `hub_core` (path `packages/hub_core`), `flutter_secure_storage`, `mobile_scanner`; shared with the TV flavor (see size gate).
- `lib/main_phone.dart`, `lib/phone/` -- new: `phone_controller.dart` (wraps `HubClient`, `ChangeNotifier`), `secure_token_store.dart`, `multicast_lock.dart`, `screens/{connect,scan,pin,home}_screen.dart`.
- `android/app/src/main/kotlin/com/codedbykay/tvsaver/MainActivity.kt` -- add `tvsaver/multicast` channel (WifiManager.MulticastLock); keep TV channels untouched.
- `android/app/src/phone/AndroidManifest.xml` (new) -- CAMERA and Wi-Fi permissions; `android/app/build.gradle.kts` has the `phone` flavor already.
- `packages/hub_core/lib/src/hub_client.dart` (`connectFromQrUri`, `reconnectSavedHub`, `submitPin`, `state`, `request`), `hub_scanner.dart`, `token_store.dart` (`HubTokenStore`, `SavedHubPairing`, `MemoryHubTokenStore`) -- reuse; do not fork.
- `packages/hub_core/tool/fake_display.dart` -- new dev tool; `BUILD_AND_DEPLOY.md` -- phone build/install and fake display usage.
- `test/phone/` -- controller and widget tests; use `MemoryHubTokenStore`, and an in-process `HubServer` from `hub_core` where a real socket is needed.

## Tasks & Acceptance

**Execution:**
- [ ] `pubspec.yaml`, Android manifests, `MainActivity.kt` -- dependencies, permissions, multicast channel
- [ ] `lib/phone/secure_token_store.dart`, `multicast_lock.dart`, `phone_controller.dart` -- storage, lock, controller over `HubClient`
- [ ] `lib/main_phone.dart`, `lib/phone/screens/*` -- Connect, Scan, PIN, Home screens
- [ ] `packages/hub_core/tool/fake_display.dart` -- dev display stand-in
- [ ] `test/phone/**` -- tests for every matrix row (camera and mDNS rows with fakes)
- [ ] `BUILD_AND_DEPLOY.md` -- phone build, install, fake-display pairing steps

**Acceptance Criteria:**
- Given the project, when `flutter analyze` and `flutter test` run, then both pass; `flutter build apk --debug --flavor phone -t lib/main_phone.dart` succeeds.
- Given the fake display and a phone on the same Wi-Fi, when the phone scans the printed QR, then it pairs as owner and survives an app restart and a Pi restart without scanning again.
- Given a release TV build, when compared with the 3-2 baseline, then the APK grew by at most 8 MB.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `flutter analyze && flutter test` -- expected: no issues, all tests pass
- `flutter build apk --debug --flavor phone -t lib/main_phone.dart` -- expected: success
- `cd packages/hub_core && dart analyze && dart test` -- expected: still passing
- `flutter build apk --release --flavor tv -t lib/main_tv.dart --target-platform android-arm` -- expected: size delta ≤ 8 MB vs before

**Manual checks:**
- Kay installs the phone APK, runs `fake_display.dart` against the Pi, scans the QR and sees the owner role and device list.
