---
title: 'Roles, pairing relay and recovery'
type: 'feature'
created: '2026-11-24'
status: 'in-progress'
baseline_commit: '6c38fe41291bebd8183ef847c1edc77fd2efd5a6'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi hub runs but cannot pair anything: it registers no `DevicesModule`, has no `display` device kind, and its pairing code is meant for a TV-hosted server. Without this, no phone or TV can join and nobody can recover from a lost owner phone (CAP-7).

**Approach:** In `hub_core`, add the `display` kind and role rules, relay pairing to the display (`devices.startPairing` → targeted `display.pairing` frames), add `devices.approveDisplay`, `devices.forgetAll` and the admin reset, and wire `DevicesModule` and the new flow into `PiServer`.

## Boundaries & Constraints

**Always:**
- Display socket says `hello {kind: "display"}`; phones omit `kind`. A display device has role `display`, is never owner, and its requests count as owner-equivalent (physical presence).
- First display: no display paired → accepted without PIN and given a token. Display already paired, new display without a valid token: if a paired phone exists it waits (≤120 s) for `devices.approveDisplay {requestId}` from any paired phone, which gets a targeted `devices.approvalRequested {requestId, name}`; if no phone is paired it is accepted and replaces the old display. If the existing display is connected, the newcomer gets `err {code: conflict}`.
- Phone role: first paired phone is `owner` (election counts only phones, owner absent → owner), later phones `controller`. Max 8 connections: 1 display + 7 phones.
- `devices.startPairing` / `devices.cancelPairing` (display only): the Pi opens or closes a pairing session and sends the display targeted `display.pairing {qr, pin, expiresAt}` now and on every rotation and after each pairing. The QR host is the display socket's local address and the hub port. Same rules as now: single use, 120 s, 3 wrong tries → 60 s lockout. Phones pairing while no session is open get `err {code: unavailable}`.
- `devices.forgetAll` (owner or display): deletes all phone pairings, closes phone sockets, display stays connected. `device.forget` and rename keep working.
- Admin: `tvsaver admin reset-pairings` (args to `bin/pi_server.dart`). If the server runs, the CLI calls `POST /admin/reset-pairings` on 127.0.0.1 with the static bearer token (loopback peers only); the server deletes every device and closes all sockets. If it is not running, the CLI deletes the rows in the database file directly. Exit non-zero with a short message on failure.
- Media routes accept the static bearer token or any paired device token (TV streaming keeps working).
- No mention of Drawing Aid or drawing_poc anywhere in code, tests or docs.

**Never:**
- No `player`, `library`, `playlist`, `settings` modules; no TV or phone app changes; no QR rendering; no removal of the static media token; no TLS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| First display | No display paired, `hello {kind: display}` | Token issued, role `display`, ready | — |
| Second display, first online | Display connected | — | `err conflict` |
| New display, phone paired | Old display offline | Waits; phone approves → token | 120 s timeout → `err timeout`, close |
| New display, no phone | Old display offline | Accepted, old display row replaced | — |
| Phone pairs by QR | Display called `startPairing`, valid `pairCode` | Phone becomes owner (first) or controller | Code reused/wrong → lockout rules |
| Phone, no session | No `startPairing` | `err unavailable` | — |
| Forget all phones | Display or owner sends `devices.forgetAll` | Phone rows and sockets gone; next phone is owner | Controller → `err forbidden` |
| Admin reset, server up | Loopback POST with token | All devices deleted, all sockets closed | Wrong token → 401; non-loopback → 403 |
| Admin reset, server down | CLI only | DB rows deleted | Missing DB file → message, exit 1 |

</frozen-after-approval>

## Code Map

- `packages/hub_core/lib/src/server/hub_server.dart` -- `_beforeReady` (hello paths A/B/C), `_issueTokenAndProceed`, `openPairingSession`/`rotatePairingCredentials`/`currentQrUri`, `forgetPairings`, `_becomeReady` (`ready` carries role), `authenticateHttp`, `requireOwner` checks at ~286 and ~844 (make display owner-equivalent).
- `packages/hub_core/lib/src/server/hub_module.dart` -- `DeviceRole` (add `display`), `DeviceInfo`; targeted events via `HubOutboundEvent.targeted`.
- `packages/hub_core/lib/src/server/devices_module.dart` -- add `devices.startPairing/cancelPairing/approveDisplay/forgetAll`; today only `device.rename`/`device.forget`.
- `packages/hub_core/lib/src/db/hub_database.dart` -- `nextDeviceRole`, `deleteAllPairings`; add `deleteAllDevices`, phone-only counting; role column stays text (`owner|controller|display`), no schema change.
- `packages/hub_core/lib/src/server.dart` (`PiServer`) -- register `DevicesModule`; add loopback `/admin/reset-pairings`; accept device tokens on `/media`.
- `packages/hub_core/bin/pi_server.dart` -- `admin reset-pairings` subcommand; binary on the Pi is `~/tvsaver/bin/tvsaver`.
- `packages/hub_core/test/support/fake_phone_harness.dart`, `pairing_and_roles_test.dart` -- extend harness with a fake display.
- `BUILD_AND_DEPLOY.md` -- Pi server section: pairing, roles, admin reset.

## Tasks & Acceptance

**Execution:**
- [ ] `hub_module.dart`, `hub_database.dart` -- `display` role, phone-only owner election, `deleteAllDevices`
- [ ] `hub_server.dart` -- `kind` in hello, first/approved/replacement display flow, pairing sessions gated on `startPairing`, `display.pairing` relay, owner-equivalent display, `forgetAll`, `resetAll`
- [ ] `devices_module.dart` -- new handlers and `devices.approvalRequested`
- [ ] `server.dart`, `bin/pi_server.dart` -- register module, admin endpoint and CLI, device-token media auth
- [ ] `test/**` -- fake display in harness; tests for every matrix row; media with device token still 200/206
- [ ] `BUILD_AND_DEPLOY.md` -- document recovery

**Acceptance Criteria:**
- Given the matrix, when `dart analyze` and `dart test` run in `packages/hub_core`, then all pass.
- Given a display and two phones paired, when the display sends `devices.forgetAll`, then both phones are disconnected, the display stays, and the next phone to pair is owner.
- Given `reset-pairings` ran, when a display and phone connect, then the display is first display and the phone is owner.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `cd packages/hub_core && dart analyze && dart test` -- expected: no issues, all tests pass
- `cd packages/hub_core && dart compile exe bin/pi_server.dart -o build/pi_server_check` -- expected: success
