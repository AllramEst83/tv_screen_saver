---
title: 'Pi file server with auth and Range, systemd and Avahi'
type: 'feature'
created: '2026-11-23'
status: 'done'
baseline_commit: '28afb2f53e240fde8464b8c73a2c286ed6fccaa3'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/lan-setup.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Nothing serves media from the Pi yet. The TV cannot stream a playlist (CAP-2), and the Pi has no always-on service that starts at boot, answers `/health`, or advertises itself on the LAN (CAP-11, CAP-7).

**Approach:** Create the pure-Dart `packages/hub_core` package with a minimal authenticated HTTP file server (`/health`, `GET|HEAD /media/<id>/full` with `Range`/`206`), compile it to a linux-arm64 AOT executable from the PC, and ship deploy tooling plus a sudo install script (systemd unit + Avahi `_tvsaver._tcp`) that Kay runs once on the Pi. A temporary static bearer token stands in until pairing arrives in story 3-2.

## Boundaries & Constraints

**Always:**
- `packages/hub_core` is pure Dart (no Flutter imports) with its own `pubspec.yaml`; the entry point is `packages/hub_core/bin/pi_server.dart` (update `architecture.md` "Code layout" to match). It uses only `dart:io` and light, pure-Dart packages.
- Binds `0.0.0.0:8772`. `GET /health` needs no auth and returns `{ok, id, v, clients}` (`clients` = 0 for now). Every other route requires `Authorization: Bearer <token>`; `401` without or with a wrong token (constant-time compare); tokens never appear in URLs, logs or argv.
- Media route: `GET|HEAD /media/<id>/full` serves the file `<media dir>/<id>` (default `~/tvsaver/media`; `id` restricted to `[A-Za-z0-9._-]`, no traversal). `Accept-Ranges: bytes`; single `Range` → `206` + `Content-Range`; open-ended and suffix ranges; unsatisfiable → `416` with `Content-Range: bytes */<size>`; no `Range` → `200`. Files stream from disk (no whole-file buffering; files may be many GB). Other variants → `404` for now. Content-Type from the extension (mp4, mkv, jpg, png, default octet-stream).
- Temporary token: read from `~/.config/tvsaver/token` (override `TVSAVER_TOKEN_FILE`); if the file is missing the server creates it with a random 32-byte token (hex), mode 0600, and logs only its path.
- Cross-compile on the PC: `dart compile exe --target-os linux --target-arch arm64`; deploy copies the binary to `~/tvsaver/bin/tvsaver` atomically (copy to `.new`, `mv`) and restarts it by `pkill -x tvsaver` (no sudo; systemd `Restart=always` relaunches it).
- `tool/pi/install_server.sh` (Kay runs `sudo bash`): installs `tvsaver.service` (`WantedBy=multi-user.target`, `After=`/`Wants=network-online.target`, `Restart=always`, `RestartSec=5`, `User=allramest`) and the Avahi file for `_tvsaver._tcp` on port 8772, enables and starts both; idempotent; `--dry-run`.
- A smoke test from the PC (`tool/pi/smoke_test.sh`) exercises the real Pi: `/health` 200, no token 401, valid token + Range 206 with correct `Content-Range` and body bytes, `416`, HEAD, traversal attempt rejected.

**Never:**
- No database, library, uploads, pairing, WebSocket, variants/worker (later stories); no TV or phone app changes; no TLS.
- No sudo from this session; no token printed or committed.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Health | `GET /health`, no token | `200 {"ok":true,"id":…,"v":…,"clients":0}` | N/A |
| No/wrong token | any other route | `401` | no detail about why |
| Full file | `GET /media/clip/full` + token | `200`, `Content-Length`, `Accept-Ranges: bytes` | N/A |
| Range middle | `Range: bytes=100-199` | `206`, `Content-Range: bytes 100-199/<size>`, exactly those bytes | N/A |
| Open-ended / suffix | `bytes=500-` / `bytes=-100` | `206` with the correct start..end | N/A |
| Beyond end | `bytes=<size>-` | `416`, `Content-Range: bytes */<size>` | N/A |
| Multi-range | `bytes=0-1,5-6` | `200` full file (ranges ignored) or `416`; never a malformed 206 | document the choice |
| HEAD | `HEAD /media/clip/full` | headers only, same as GET | N/A |
| Missing / bad id | unknown id, `../x`, `a/b` | `404` / `400` | no path leakage |
| Client aborts | connection closed mid-stream | file handle closed, server keeps running | no crash |
| Restart | process killed | systemd relaunches in ~5 s; `/health` answers again | N/A |

</frozen-after-approval>

## Code Map

- `_bmad-output/specs/spec-tv-screensaver/media-server.md` -- route rules, Range requirement, auth rule, limits (this story implements `/health` and the Range part of `/media/<id>/<variant>` only).
- `_bmad-output/specs/spec-tv-screensaver/architecture.md` -- "Code layout": says `bin/pi_server.dart` at repo root; change to `packages/hub_core/bin/pi_server.dart`.
- `_bmad-output/specs/spec-tv-screensaver/lan-setup.md` -- "Unattended boot": the exact `tvsaver.service` settings; Avahi `_tvsaver._tcp`, port 8772.
- `tool/pi/setup_wifi.sh`, `tool/pi/deploy.sh`, `tool/pi/units/` -- patterns for Pi scripts (idempotent, `--dry-run`, root check, LF endings via `tool/pi/.gitattributes`, `PI_HOST`/`PI_USER`/`PI_KEY`).
- Pi facts: `gemini-pi`, aarch64 Debian 13, user `allramest` (no passwordless sudo), on Floor 1 at 192.168.0.43; no Dart installed; `avahi-utils` installed, `avahi-daemon` enabled; nothing listens on 8772; `/etc/avahi/services/` writable only by root; `~/tvsaver/pi/` already holds the Wi-Fi scripts.
- Tools on the PC: Dart SDK 3.13.0 (supports `--target-os linux --target-arch arm64`), `curl`, Git Bash; the root `pubspec.yaml` is a Flutter app, so `hub_core` must be a separate package under `packages/`.

## Tasks & Acceptance

**Execution:**
- [x] `packages/hub_core/pubspec.yaml`, `analysis_options.yaml` -- pure Dart package -- shared server code.
- [x] `packages/hub_core/lib/src/**` -- config (paths, token), auth, health route, range parsing, media route, mime types -- the server.
- [x] `packages/hub_core/bin/pi_server.dart` -- entry point wiring config and starting `HttpServer` -- executable.
- [x] `packages/hub_core/test/**` -- unit/integration tests on a loopback server and temp dir covering every matrix row -- regression.
- [x] `tool/pi/deploy_server.sh` -- compile for linux-arm64, atomic copy, restart via `pkill` -- PC-side deploy.
- [x] `tool/pi/install_server.sh`, `tool/pi/units/tvsaver.service`, `tool/pi/units/tvsaver.avahi.service` -- Kay's one-time sudo install -- boot start + discovery.
- [x] `tool/pi/smoke_test.sh` -- real-Pi checks via curl -- acceptance.
- [x] `_bmad-output/specs/spec-tv-screensaver/architecture.md`, `BUILD_AND_DEPLOY.md` -- code layout fix; Pi server runbook -- documentation.

**Acceptance Criteria:**
- Given `dart test` in `packages/hub_core`, when run, then all matrix rows pass.
- Given `deploy_server.sh`, when run, then `~/tvsaver/bin/tvsaver` is an executable ELF aarch64 and a run of it on the Pi answers `/health` on 8772.
- Given Kay ran `sudo bash ~/tvsaver/pi/install_server.sh`, when the Pi reboots, then `tvsaver` is active, `/health` answers within 2 minutes, and `avahi-browse -rt _tvsaver._tcp` lists it.
- Given `smoke_test.sh`, when run against the Pi, then every check passes, including a 206 Range read from the middle of a 1 GB file in under 3 s.

## Implementation Notes

- All 12 triaged review patches (#1–#12) applied; #13 and #14 recorded in `_bmad-output/implementation-artifacts/deferred-work.md`.
- Live redeploy verification caught that Dart AOT sets `/proc/<pid>/comm` to `dart:tvsaver` rather than `tvsaver`; `tool/pi/deploy_server.sh` matches the full binary path `^$HOME/tvsaver/bin/tvsaver($|[[:space:]])` (and `BUILD_AND_DEPLOY.md` documents `pkill -x dart:tvsaver`).
- Verified on `gemini-pi` (192.168.0.43): `dart analyze` clean, `dart test` 19/19 passed, `install_server.sh` `--dry-run` + apply (5/5 changes), reboot recovery (< 2 min, `tvsaver` active, Avahi `_tvsaver._tcp` on port 8772), `smoke_test.sh` 21/21 passed (token mode `600`, 1 GiB middle Range in 0.35 s), and live `deploy_server.sh` restart (PID 850 → 1311, `/health` ok).

## Spec Change Log

## Review Triage Log

| # | Source | Finding | Verdict | Evidence / route |
|---|---|---|---|---|
| 1 | blind + edge | Unexpected handler errors are swallowed: `start`'s `catchError` closes with the default 200 and an empty body, nothing is logged | medium | Verified `server.dart` `start` → patch (500 + stderr log of method/path, never headers) |
| 2 | blind + edge + verif-gap | Mid-stream read errors (file removed/short read) leave the response open with a declared Content-Length; client hangs or sees a short body | medium | Verified `_serveFile` `catch (_)` → patch (log, destroy the connection when it is not a client abort) |
| 3 | blind + edge | A symlink inside the media dir is followed by `stat`/`openRead` | medium | Real escape variant of the traversal rule → patch (`isLink` → 404) |
| 4 | blind + edge | `Bearer` scheme match is case-sensitive | low | RFC 7235; one-line fix → patch |
| 5 | edge + verif-gap | Suffix range with > 18 digits returns 416 (should be whole-file 206); suffix > file size, `bytes=0-0`, `Bytes=`, clamped-end status untested | medium | Pre-verified `range.dart:178-182` → patch (code + tests) |
| 6 | verif-gap + blind | 405 for POST/PUT on `/health` and `/media` untested; `ServerConfig.fromEnvironment` and MIME types untested | medium | Pre-verified → patch (tests) |
| 7 | blind | MIME map lacks .mov/.webm/.webp/.gif/.avif/.heic | low | Cheap, library will meet these → patch |
| 8 | edge + blind + verif-gap | Token file: `chmod` exit code ignored; mode 0600 only asserted off-Windows, never checked on the Pi | medium | Verified `config.dart` + test skip → patch (check exit code; smoke test checks mode 600 over ssh) |
| 9 | edge | `smoke_test.sh`: predictable `/tmp` path and a literal `/tmp` handed to Windows curl under `MSYS_NO_PATHCONV=1`; no early abort when `/health` fails | medium | Windows curl would write to the wrong place → patch (`mktemp` + `cygpath -m`, early abort) |
| 10 | edge | `deploy_server.sh` reports success without checking the new binary came up | medium | pkill + exit 0 → patch (poll `/health` up to 15 s when a process was killed; note when none was running; keep `tvsaver.prev` for rollback) |
| 11 | edge | `install_server.sh`: `enable --now` failure exits silently; dry-run under-reports restart/avahi reload | medium | Dry-run is Kay's safety preview → patch |
| 12 | blind | Runbook: plain-HTTP token on the LAN, how to read/rotate it, rollback, reboot check without pass/fail wording | medium | Real doc gaps → patch (docs) |
| 13 | verif-gap | Traversal test accepts 400 or 404 (explicit `..` guard unobserved) | low | No exposure today (directory check yields 404) → defer |
| 14 | verif-gap + blind | No automated test for `install_server.sh` idempotence/dry-run (fake systemctl harness) | low | Real-Pi manual step is the stated check; same pattern as story 2-1 → defer |
| 15 | blind | No `ETag`/`Last-Modified`/`If-Range`/`Cache-Control`, no `Allow` header on 405, no `WWW-Authenticate` | low | Not required by the spec; clients are ours → rejected |
| 16 | blind | Unit hardening (`NoNewPrivileges`, `ProtectSystem`…), hardcoded user/path, Avahi TXT records/port | low | Single-user home appliance; spec fixes port 8772 → rejected |
| 17 | blind | Concurrent first start can write two tokens; unreadable token gives a raw exception | low | Single service instance under systemd → rejected |
| 18 | blind + edge | `stop(force: true)` cuts active streams on redeploy; no access logging | low | Redeploy restarts the process anyway; access logs would risk leaking paths → rejected |
| 19 | edge | `//` paths alias routes; invalid `TVSAVER_PORT` silently falls back; media dir creation failure gives a stack trace | low | Cosmetic/unlikely → rejected |
| 20 | edge | `install_server.sh` re-reports "enable and start" when inactive; missing `avahi-daemon`; hardcoded `TVSAVER_BIN` | low | avahi-daemon is installed and enabled on the Pi (verified) → rejected |
| 21 | edge (claim) | `architecture.md` Code layout not updated | false | Updated by the implementer (outside the review diff's path filter) |
| 22 | blind | Smoke test does not check mDNS/Avahi, HEAD `/health`, or timing flakiness | low | Avahi is checked manually per the acceptance criteria → rejected |

## Verification

**Commands:**
- `dart analyze` and `dart test` in `packages/hub_core` -- expected: no issues, all pass
- `bash tool/pi/deploy_server.sh` -- expected: binary on the Pi
- `bash tool/pi/smoke_test.sh` -- expected: all checks pass (after the server runs on the Pi)
- `bash -n tool/pi/*.sh` -- expected: no syntax errors

**Manual checks (if no CLI):**
- Kay: `sudo bash ~/tvsaver/pi/install_server.sh --dry-run`, then without it; reboot the Pi once and confirm `/health` and the Avahi listing.
