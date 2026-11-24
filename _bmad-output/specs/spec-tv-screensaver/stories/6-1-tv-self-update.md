---
title: 'TV self-update'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: 'd407bb2'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** Every TV update is an adb install from a PC on Floor 1.

**Approach:** The TV finds, downloads, sha256-verifies and opens the installer for a new APK (CAP-10). Decision of 2026-11-24: the desktop PC runs the update server (not the Pi), and no new keystore work: the build is signed as before.

## Implementation Notes

- PC: `UpdateServer` in hub_core (`update_server.dart`: `GET /update.json`, `GET /tv-saver-tv.apk`, HEAD, checksum cached by APK size and time) and the thin CLI `tool/serve_tv_update.dart`.
- TV: `TvUpdater` (`lib/tv/update/updater.dart`, ported from drawing_poc: check, download with stall timeout, sha256, installer, retry), `FileUpdateSourceStore`, `UpdateScreen` (Menu key, Down; Up edits the address), a menu line when an update is ready, a quiet check at start. Native: `tvsaver/installer` in `MainActivity.kt` (FileProvider on the app cache, `REQUEST_INSTALL_PACKAGES`, opens the system "install apps" screen when not allowed), manifest provider and `file_paths.xml` in the TV flavor only.
- The existing `update_manifest.dart` and the "same host and port" rule for the APK address stay.
- Tests: hub_core update manifest and server (10), TV updater (17 ported), source store, update screen and menu (8). The TV release and phone debug APKs build, the merged TV manifest has the permission and provider, and the real tool served the real APK with the right checksum.
- Not verified on the TV: the system installer and the "install unknown apps" screen on the X90K's Android, typing the address with the remote's keyboard, and an actual update from build N to N+1. The first update has to be installed by adb (the installed app must already contain this code).
