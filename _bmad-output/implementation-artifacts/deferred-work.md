- source_spec: `_bmad-output/specs/spec-tv-screensaver/stories/1-1-tv-spike-app-with-displayreport.md`
  summary: Add automated checks for tool/tv/display_report.sh (fake-adb harness for exit codes 0/1/2 and "no file when unreachable", plus shellcheck in the pre-ship checks).
  evidence: Review triage #13 — the script's exit-code contract is only verified by manual runs; no shell test harness exists in the repo yet.
