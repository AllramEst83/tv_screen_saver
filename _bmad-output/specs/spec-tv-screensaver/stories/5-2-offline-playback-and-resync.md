---
title: 'Offline playback and resync'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '723e1df'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** With the Pi down the TV can only loop one item, and the remote does nothing.

**Approach:** The Pi gives the TV the current playlist (`display.playlist`); without the Pi the TV plays the cached items of it in order and the remote acts locally; on return the TV's report is adopted with no jump. Contract: `modules.md` "Offline and resync (story 5-2)".

## Implementation Notes

- Pi: `DisplayModule.sendPlaylist`, `PlayerModule._sendPlaylist` (keyed by playlist and order; cleared on TV reconnect; also sent after an adopted report).
- TV: `OfflinePlaylist` (`offline_playlist.dart`), `DisplayClient._advanceLocally`, offline branches of `next`, `prev`, `togglePause`, `seekBy` and `_reportEnded`; `_report` uses the offline list so the Pi finds the item.
- A video that only streams stops when the Pi goes; the error path then moves to the next cached item.
- Tests: Pi (3), TV real-hub offline scenario (5): loop of cached photos, skipping uncached, remote, one cached item, return and adoption without reloading.
- Not verified on the real Pi and TV: pulling the Pi power while the TV plays, video from the cache under Media3 (file URI), how long the Wi-Fi retry takes to notice the return.
