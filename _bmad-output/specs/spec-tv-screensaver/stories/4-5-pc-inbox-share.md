---
title: 'PC inbox share'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: 'ecaac96'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** Large 4K and HDR masters should not go through the phone.

**Approach:** A Samba share `inbox` on the Pi and a watcher in the server that imports each file once it is stable, with the same checks as an upload; refused files move to `inbox/rejected/` with a reason.

## Implementation Notes

- `LibraryStore.importFile` (duplicate sha256, type, size limits, storage cap and free space, streaming-ceiling rule for video; an image above 4096 px goes through `MediaTools.fitImage`, vips thumbnail q95 with `keep=icc`; the file is moved, not copied). `InboxWatcher` (polls every 5 s, a file must be unchanged for 10 s, ignores dot and `~` files and folders). `ServerConfig.inboxDir` (`TVSAVER_INBOX_DIR`, default `~/tvsaver/inbox`; null turns it off, as in tests).
- `tool/pi/setup_inbox.sh` (idempotent, `--dry-run`, never stores a password) with `tool/pi/test/test_inbox_script.sh`; `deploy.sh` copies it. BUILD_AND_DEPLOY section 15.
- Tests: `inbox_test.dart` (10), script test (13 checks).
- Not verified on the real Pi: Samba itself, vips scaling of a real 6000 px photo (a fake runner is used), a multi-GB file moving over the SD card.
- Decision: a duplicate is moved to `rejected/` with "Already in the library" rather than deleted.
