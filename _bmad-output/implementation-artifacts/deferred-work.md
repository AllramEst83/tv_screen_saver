- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-1-tv-spike-app-with-displayreport.md`
  summary: Add automated checks for tool/tv/display_report.sh (fake-adb harness for exit codes 0/1/2 and "no file when unreachable", plus shellcheck in the pre-ship checks).
  evidence: Review triage #13 — the script's exit-code contract is only verified by manual runs; no shell test harness exists in the repo yet.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-1-tv-spike-app-with-displayreport.md`
  summary: Add an Android instrumented/integration test that checks the Kotlin `tvsaver/display` `panelSize` channel against the Dart `fetchPanelSize` contract (channel, method and key names).
  evidence: Review triage #22 — the Dart tests mock both sides; a key or channel rename would only show on the TV as "(panel unverified)". Verified manually on the X90K on 2026-11-23.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-2-video-path-spike.md`
  summary: Add automated tests for the Kotlin `VideoSpike.kt` helpers (`hdrName`, `hevcProfileName`, `probe`) and for `tool/video/*.sh` (fake adb/ffmpeg harness).
  evidence: Review triage #10 — these paths need a device or ffmpeg; today they are verified only by the manual runbook and the 2026-11-23 real runs.
- source_spec: `_bmad-output/implementation-artifacts/soak-run-design.md`
  summary: Build the always-on soak tooling (in-app CSV recorder, soak_sample.sh, soak_report.sh with pass thresholds) as part of story 5-4; keep wakelock/immersive in 5-1.
  evidence: Kay decided on 2026-11-23 that enough on-TV testing was done in phase 1 and asked to move on to building the app; the 8 h run and the TV settings checklist move to 5-4.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/2-1-pi-wifi-pinning.md`
  summary: Run `tool/pi/test/test_wifi_scripts.sh` automatically (pre-commit/CI wrapper) instead of by hand.
  evidence: Review triage #10 — nothing in the repo invokes the Pi script tests; same gap as the shell scripts from story 1-2.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/2-2-pi-file-server.md`
  summary: Make the traversal test strict (assert 400 for `%2e%2e`) and add a fake-systemctl harness test for `tool/pi/install_server.sh` idempotence and `--dry-run`.
  evidence: Review triage #13 and #14 — the explicit `..` guard is unobserved by tests and the install script is verified only by the manual real-Pi run.
