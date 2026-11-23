---
title: 'Pi Wi-Fi pinning to Floor 1 with fallback'
type: 'feature'
created: '2026-11-23'
status: 'done'
baseline_commit: 'e273454a5437852dfee5b4a046d6d553aadb5fc5'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/SPEC.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/lan-setup.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi picks between `LightSpeed_Auto_Floor_1` and `LightSpeed_Auto_Floor_2` by whatever NetworkManager prefers (both profiles autoconnect at priority 0), and it is on Floor 2 now. The TV and phones live on Floor 1, so after a power cut the Pi may come back unreachable for them (CAP-11).

**Approach:** An idempotent setup script, run on the Pi by Kay with `sudo`, that pins Floor 1 (priority 100, retry forever, 5 GHz when the Pi can see it), keeps Floor 2 as the low-priority fallback, disables autoconnect on every other Wi-Fi profile, and installs a systemd timer that returns the Pi to Floor 1 within 2 minutes of it reappearing. PC-side scripts deploy and check it.

## Boundaries & Constraints

**Always:**
- Privileged steps live in scripts Kay runs as `sudo bash …` over SSH (`allramest` has no passwordless sudo and NetworkManager modify/scan need auth). The PC-side deploy copies files with `scp` only, no sudo, and never touches the TV.
- Profiles per `lan-setup.md`: Floor 1 `autoconnect-priority 100`, `autoconnect-retries 0`; Floor 2 `autoconnect-priority 10`; every other 802-11-wireless profile `autoconnect no`; the wired profile is left as is.
- **5 GHz lock only if safe:** the script scans (`--rescan yes`) and sets `802-11-wireless.band a` on Floor 1 only when a 5 GHz BSS of Floor 1 is visible with signal ≥ 40; otherwise it leaves the band unset and prints a warning, so the Pi can never be stranded by the lock.
- **Passwords optional:** read `/home/allramest/.config/tvsaver/.env` (`WIFI_FLOOR1_PSK`, `WIFI_FLOOR2_PSK`, SSIDs). If the file is missing or a PSK is empty the saved profile PSK is left untouched. PSKs are never printed, logged, put in argv visible to `ps`, or committed (no `set -x`; `nmcli … --ask`/stdin or a temp file with `chmod 600` removed on exit).
- The return-to-Floor-1 timer (`tvsaver-wifi-prefer.timer`, every 60 s, plus its service) acts only if the active Wi-Fi profile is Floor 2 and a rescan shows Floor 1; it uses `flock` so runs never overlap, logs one line per decision to the journal, and on failure leaves NetworkManager to fall back to Floor 2 on its own.
- `--dry-run` prints the planned changes without applying them; re-running changes nothing.
- The PC-side tools tolerate that `gemini-pi.local` may not resolve after the Pi moves to Floor 1: host comes from `PI_HOST` (default `gemini-pi.local`).

**Never:**
- No Pi server, systemd unit for the server, Samba or package installs (later stories).
- No change to the Floor 2 router, the TV, or any password in git.
- Never run privileged commands from this PC session.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Setup run twice | profiles already configured | second run reports "no changes" | N/A |
| Floor 1 visible only on 2.4 GHz or weak | scan finds no ≥ 40 signal 5 GHz BSS | band lock skipped, warning printed | N/A |
| `.env` missing | no file | PSKs untouched, message says so | no failure |
| Active = Floor 2, Floor 1 visible | timer fires | `nmcli con up Floor 1`; journal line | `up` fails → stay on Floor 2, journal line, retry next minute |
| Active = Floor 1 | timer fires | exits quietly (no rescan) | N/A |
| Profile missing | Floor 1 profile not found | script exits non-zero naming the profile, changes nothing | no partial state |
| Not root | script run without sudo | exits non-zero with "run with sudo" | no changes |

</frozen-after-approval>

## Code Map

- `_bmad-output/specs/spec-tv-screensaver/lan-setup.md` -- "Wi-Fi selection": priorities, timer behaviour, `.env` format (passwords now optional; 5 GHz lock conditional — update this file to match).
- Pi facts (read-only inspection 2026-11-23): `gemini-pi`, aarch64 Debian 13, NetworkManager active; profiles `LightSpeed_Auto_Floor_2` (active, 192.168.1.207, priority 0), `LightSpeed_Auto_Floor_1` (priority 0, no band set), `Wired connection 1` (priority -999); `nmcli general permissions` shows modify/scan = `auth` for `allramest`; `sudo -n` needs a password; `~/.config/tvsaver/` does not exist; avahi enabled, avahi-utils installed.
- `tool/tv/display_report.sh`, `tool/video/push_clips.sh` -- patterns for Git Bash scripts (`MSYS_NO_PATHCONV=1`, `cygpath -m`); SSH uses `-i ~/.ssh/id_ed25519_claude -o BatchMode=yes`.
- `BUILD_AND_DEPLOY.md` -- add a Pi section (deploy, setup, check, test procedure).

## Tasks & Acceptance

**Execution:**
- [x] `tool/pi/setup_wifi.sh` -- idempotent root script: profile settings, conditional 5 GHz lock, optional PSKs, installs the timer units, `--dry-run` -- the pinning.
- [x] `tool/pi/wifi_prefer.sh` -- the timer's action (flock, journald, Floor 2 → Floor 1 return) -- unit `ExecStart`.
- [x] `tool/pi/units/tvsaver-wifi-prefer.service`, `.timer` -- systemd units, 60 s, `Persistent=false` -- the periodic check.
- [x] `tool/pi/deploy.sh`, `tool/pi/check_wifi.sh` -- PC-side: scp `tool/pi/` to `~/tvsaver/pi/`, create `~/.config/tvsaver/.env.example` (no secrets); read-only status (active profile, band, signal, IP, timer state, last journal lines) -- Kay's workflow.
- [x] `tool/pi/test/test_wifi_scripts.sh` -- fake `nmcli`/`systemctl` on PATH: idempotence, band-lock rule, `.env` handling, timer decisions, PSK never in output -- regression.
- [x] `_bmad-output/specs/spec-tv-screensaver/lan-setup.md`, `BUILD_AND_DEPLOY.md` -- updated wording and runbook -- documentation.

**Acceptance Criteria:**
- Given the test harness, when `test_wifi_scripts.sh` runs, then every matrix row passes.
- Given `deploy.sh`, when run from the PC, then the scripts and `.env.example` are on the Pi and `check_wifi.sh` prints the current state without any PSK.
- Given Kay runs `sudo bash ~/tvsaver/pi/setup_wifi.sh` and reboots with Floor 2 stronger, when the Pi is back, then `check_wifi.sh` shows Floor 1 active (5 GHz if it was eligible); with Floor 1 off at boot it shows Floor 2, and within 2 minutes of Floor 1 returning it is back on Floor 1.

## Implementation Notes

- Privileged steps are scripts Kay runs with `sudo` on the Pi (no passwordless sudo; NetworkManager modify/scan need auth). `deploy.sh` (scp only) already copied everything to `~/tvsaver/pi/` on 2026-11-23; `setup_wifi.sh` has NOT been run on the real Pi (needs sudo), so real `nmcli` behaviour is verified only for read paths: `FREQ` prints like `5180 MHz`, `BAND` is not a valid list field in nmcli 1.52.1 (not used), profile names equal their SSIDs.
- Review loop 1 patches: stale 5 GHz lock is cleared, Floor 2 retries 0, install failures abort, timer restarted on change, timer needs signal >= 40 (+ band match), 10 min back-off after a failed switch, offline recovery when no Wi-Fi is active, `TimeoutStartSec=90`, 18 more test cases (64 total), runbook rewritten (PI_HOST by Floor 1 IP, undo steps, explicit reboot tests).
- Pi observation: the Pi's cached scan lists only `LightSpeed_Auto_Floor_2` (5180 MHz, signal 72); Floor 1 was not visible from the Pi's location at that moment. `setup_wifi.sh` rescans and warns; if Floor 1 stays invisible the Pi must be moved closer to the Floor 1 router before the TV can reach it.
- Still open (Kay): `sudo bash ~/tvsaver/pi/setup_wifi.sh --dry-run`, then without `--dry-run`; the three reboot tests in BUILD_AND_DEPLOY.md section 9; report `check_wifi.sh` output.

## Spec Change Log

## Review Triage Log

| # | Source | Finding | Verdict | Evidence / route |
|---|---|---|---|---|
| 1 | edge + blind + claim | A previously set `band a` is never cleared when 5 GHz is not (or no longer) eligible, stranding the Pi | high | Verified `setup_wifi.sh:107-111` ("existing band setting left as is") vs the spec's "leaves the band unset… never stranded" → patch |
| 2 | blind + edge | Timer switches to Floor 1 on any sighting (no signal floor), no back-off after failures; a failing `up` drops the working Floor 2 link every minute | high | Verified `wifi_prefer.sh:32-37` → patch (signal >= 40, band match, 10 min back-off after a failure) |
| 3 | edge | Timer ignores the "no active Wi-Fi profile" case; Pi can stay offline | medium | Verified `wifi_prefer.sh:30` exits unless Floor 2 is active → patch |
| 4 | edge (claim) | Floor 2 keeps default autoconnect-retries (4), so the fallback can stop retrying | medium | Only Floor 1 gets retries 0 → patch (retries 0 on Floor 2) |
| 5 | blind + edge | Oneshot service has no start timeout; a hung rescan holds the lock and the unit | medium | Verified units → patch (`TimeoutStartSec=90`) |
| 6 | edge | `install_file` failures hidden inside `&&` lists; script reports success and enables a timer whose script is missing | medium | Verified `setup_wifi.sh:129-131` → patch |
| 7 | edge | Updated units/script not applied while the timer is already active | low | `daemon-reload` only → patch (restart the timer when files changed) |
| 8 | verif-gap + blind | No tests for CRLF/quoted `.env`, custom SSID, missing Floor 2, and the new rules above | medium | Pre-verified → patch (tests) |
| 9 | blind | Runbook ignores the double-router setup, does not say other Wi-Fi profiles get autoconnect off, how to disable/revert, or that priorities apply at the next reconnect; reboot tests vague | medium | Real gaps in section 9 → patch (docs) |
| 10 | verif-gap | The Pi-script test suite is run only by hand | low | Same pattern as the 1-2 scripts → defer |
| 11 | edge | A modify failure mid-run leaves partial changes | low | Each `nmcli modify` is idempotent and re-runnable; fix folded into #6's error handling where trivial → rejected beyond that |
| 12 | edge + blind | SSIDs/profile names with `:` or `\`, or profile name != SSID | low | Both real profiles are named exactly like their SSID and contain no colon → rejected |
| 13 | edge | `.env` permission/comment/`export` handling | low | `.env` is optional and Kay-written; rejected |
| 14 | edge | `TVSAVER_TEST` bypasses the root check | low | `sudo` strips env by default; test hook only → rejected |
| 15 | edge | `flock` missing | false | `/usr/bin/flock` exists on the Pi (verified) |
| 16 | blind | Hard-coded user/paths/key | low | Single-user home appliance → rejected |
| 17 | blind | `deploy.sh` copies `check_wifi.sh` to the Pi; no checksums | low | Cosmetic → rejected |
| 18 | blind + verif-gap | Unit hardening (ProtectSystem, Nice), `Persistent=false` no-op, `lacks()` dead code, test fails if run as root | low | Cosmetic → rejected |
| 19 | blind | Failures only logged (exit 0), no failure counter in `check_wifi.sh` | low | Journal line is the record → rejected |

## Verification

**Commands:**
- `bash tool/pi/test/test_wifi_scripts.sh` -- expected: all cases pass
- `bash -n tool/pi/*.sh` -- expected: no syntax errors
- `bash tool/pi/deploy.sh && bash tool/pi/check_wifi.sh` -- expected: state printed, exit 0

**Manual checks (if no CLI):**
- Kay: run the setup with sudo, then the three reboot tests (Floor 2 stronger, Floor 1 off, Floor 1 back); report the `check_wifi.sh` output.
