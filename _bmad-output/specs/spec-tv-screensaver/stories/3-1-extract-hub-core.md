---
title: 'Extract hub_core from drawing_poc'
type: 'refactor'
created: '2026-11-24'
status: 'in-progress'
baseline_commit: '47ae7e07cd8c450b11d63244bc6f8c12098736ea'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The hub protocol, `HubServer`, `HubClient` and their test harness exist only inside Flutter-bound `../drawing_poc`. The Pi server (`packages/hub_core`) has only the 2-2 media routes, so nothing can pair, connect or run modules yet.

**Approach:** Copy the hub code into `packages/hub_core` as pure Dart, strip Flutter, port the hub-level tests to `package:test`, and make `bin/pi_server.dart` run `HubServer` on port 8772 with the 2-2 `/health` and `/media` routes mounted into it.

## Boundaries & Constraints

**Always:**
- Copy from `../drawing_poc` `lib/lan`, `lib/tv/server`, `lib/tv/db`, `lib/tv/tv_store.dart`, `test/support`. No dependency on `drawing_poc` or Flutter; `dart analyze` clean.
- `ValueNotifier`/`debugPrint` become plain `StreamController`/getters or `stdout`/`stderr`; behaviour and wire protocol stay as in drawing_poc.
- Keep: `protocol`, `clock_offset`, `hub_client`, `hub_scanner` (injectable scanner), `HubTokenStore`+`MemoryHubTokenStore`, `TvStore`+`MemoryTvStore`, `TvAdvertiser`+`NoopAdvertiser`, `HubServer`, `HubModule`, `DevicesModule`, `update_manifest`.
- Drift database keeps only `Devices` and `Pairings`; regenerate `.g.dart` with `build_runner`; `HubDatabase.inMemory()` plus a file-backed `HubDatabase.open(path)` (no `drift_flutter`); schema version 1.
- `pi_server.dart` runs one `HubServer` on 8772; the 2-2 routes (`/health` no auth, bearer-token `GET|HEAD /media/<id>/full` with Range/206) mount via `registerHttpHandler`; existing 2-2 tests still pass.

**Never:**
- Do not move `MulticastLock`, `SecureHubTokenStore`, `NsdAdvertiser`, `PrefsTvStore`, `updater.dart` (Flutter plugins; rewritten in 3-3 / 6-1).
- No Drawing Aid tables or modules (library, scene, filters, timer), no roles/pairing-relay changes (3-2), no phone/TV app edits, no change to the wire protocol.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Pi server start | `dart run bin/pi_server.dart` | One listener on 8772; `/health` 200 | Port busy → exit non-zero with message |
| Media with static token | `GET /media/x/full` + `Bearer` | Same 200/206/401/404 as 2-2 | Token never logged |
| In-process pairing | Fake phone + `HubServer` | QR/PIN pairing, roles, reconnect with token | As in drawing_poc tests |
| Lockout | 3 wrong PINs | Locked 60 s | `err` per protocol |

</frozen-after-approval>

## Code Map

- `../drawing_poc/lib/lan/{protocol,clock_offset,hub_client,hub_scanner,token_store,advertiser}.dart` -- sources; `hub_client` uses `foundation` (debugPrint) and `multicast_lock`; `token_store` keeps only the interface + memory store; `advertiser` keeps interface + Noop.
- `../drawing_poc/lib/tv/server/{hub_server,hub_module,devices_module}.dart` -- `hub_server` uses `ValueNotifier` (`pairingCredentials`, `connectedPhones`) and `foundation`.
- `../drawing_poc/lib/tv/db/hub_database.dart` -- drop Images/Albums/AlbumImages/SceneStates/SavedScenes and `drift_flutter`.
- `../drawing_poc/lib/tv/tv_store.dart` -- interface + `MemoryTvStore` only; `lib/tv/update/update_manifest.dart` -- pure, copy as is.
- `../drawing_poc/test/support/{fake_phone_harness,fake_timers}.dart`; tests `protocol_and_db_test`, `pairing_and_roles_test`, `hardening_test`, `timer_clock_sync_test` (clock-offset parts) -- port, drop Drawing Aid module wiring.
- `packages/hub_core/lib/src/server.dart` (`PiServer`, 2-2) -- split media routing into a handler mountable on `HubServer`; `lib/hub_core.dart` exports; `bin/pi_server.dart`; `pubspec.yaml` (add drift, crypto, drift_dev, build_runner, sqlite3 for native); `test/server_test.dart` must keep passing.
- `BUILD_AND_DEPLOY.md` -- Pi server section: note HubServer and the build_runner step.

## Tasks & Acceptance

**Execution:**
- [ ] `packages/hub_core/pubspec.yaml` -- add dependencies; `dart pub get` -- Flutter-free package
- [ ] `packages/hub_core/lib/src/{protocol,clock_offset,hub_scanner,hub_client,token_store,advertiser}.dart` -- copy and strip Flutter
- [ ] `packages/hub_core/lib/src/server/{hub_server,hub_module,devices_module}.dart`, `tv_store.dart`, `update_manifest.dart` -- copy and strip Flutter
- [ ] `packages/hub_core/lib/src/db/hub_database.dart` (+ generated `.g.dart`) -- Devices/Pairings only, file-backed open
- [ ] `packages/hub_core/lib/src/server.dart`, `lib/hub_core.dart`, `bin/pi_server.dart` -- mount 2-2 routes on `HubServer`; export public API
- [ ] `packages/hub_core/test/**` -- port support harness and hub-level tests to `package:test`
- [ ] `BUILD_AND_DEPLOY.md` -- update Pi server notes

**Acceptance Criteria:**
- Given the package, when `dart analyze` and `dart test` run in `packages/hub_core`, then both pass with no Flutter import anywhere (`grep -r "package:flutter" packages/hub_core` is empty).
- Given the ported tests, when run, then pairing, roles, lockout, reconnect and clock-offset cases match drawing_poc's results.
- Given `pi_server.dart` running, when `/health` and an authorised Range request are made on 8772, then they behave as in story 2-2.
- Given `dart compile exe bin/pi_server.dart`, when run for the host, then it succeeds (linux-arm64 build is checked at deploy).

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `cd packages/hub_core && dart run build_runner build && dart analyze && dart test` -- expected: no issues, all tests pass
- `cd packages/hub_core && dart compile exe bin/pi_server.dart -o build/pi_server_check` -- expected: success
