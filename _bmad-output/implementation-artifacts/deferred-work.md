- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-1-tv-spike-app-with-displayreport.md`
  summary: Add automated checks for tool/tv/display_report.sh (fake-adb harness for exit codes 0/1/2 and "no file when unreachable", plus shellcheck in the pre-ship checks).
  evidence: Review triage #13 — the script's exit-code contract is only verified by manual runs; no shell test harness exists in the repo yet.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-1-tv-spike-app-with-displayreport.md`
  summary: Add an Android instrumented/integration test that checks the Kotlin `tvsaver/display` `panelSize` channel against the Dart `fetchPanelSize` contract (channel, method and key names).
  evidence: Review triage #22 — the Dart tests mock both sides; a key or channel rename would only show on the TV as "(panel unverified)". Verified manually on the X90K on 2026-11-23.
- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-2-video-path-spike.md`
  summary: Add automated tests for the Kotlin `VideoSpike.kt` helpers (`hdrName`, `hevcProfileName`, `probe`) and for `tool/video/*.sh` (fake adb/ffmpeg harness).
  evidence: Review triage #10 — these paths need a device or ffmpeg; today they are verified only by the manual runbook and the 2026-11-23 real runs.
