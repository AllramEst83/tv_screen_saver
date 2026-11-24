---
title: 'Player polish'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '5bc303e'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** A playlist of one clip reloads at its end (a gap), the remote has no way to see what is playing, and the TV may dim or lose its full-screen mode.

**Approach:** Seamless loop for a playlist of one, an Info overlay on the remote, the wake lock while playing, and full screen re-applied on resume. Contract: `modules.md` "Player polish (story 5-1)".

## Implementation Notes

- Native: `m3OpenItem` takes `loop` (`REPEAT_MODE_ONE`). Dart: `DisplayVideoNative.open(loop)`, `DisplayPlayer.load(loop, info)`, `ItemInfo`, `active` notifier, photo snapshot position follows the photo clock.
- Pi: `_sendLoad` adds `index`, `count`, `loop`; the library name goes in as `name`.
- TV screen: `InfoOverlay`, `AwakeGuard` (`WakelockAwakeGuard`, injectable), lifecycle handling. New dependency `wakelock_plus`.
- Crossfade and Ken Burns were built in 4-6. The next clip is "pre-buffered" through the cache, not through a second Media3 player: that would be native work I cannot check without the TV.
- Tests: overlay and wake lock and resume (5), player loop/info/position (4), Pi `index`/`count`/`loop` (1). The TV release APK builds with the Kotlin change.
- Not verified on the TV: that the loop is truly gap-free with the fireplace clip's audio (the 1-2 spike showed `REPEAT_MODE_ONE` is what loops cleanly), the overlay size from the couch, wake lock behaviour on the X90K.
