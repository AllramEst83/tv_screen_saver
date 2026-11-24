---
title: 'TV cache and image pipeline'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: 'a11e35b'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** The TV only plays streamed clips. It cannot show a photo and re-downloads everything.

**Approach:** A disk LRU cache on the TV with prefetch from the Pi, and a photo path that downloads, decodes at screen size and cross-fades, with the photo's clock on the TV. Contract: `modules.md` "TV cache and photos (story 4-6)".

## Implementation Notes

- Built to the spec defaults. Nothing on the TV was measured or tuned and no TV setting was touched; the render surface is read-only from `display.capabilities`.
- Pi: `PlayerModule` gets `loadExtras`, `muteFor`, `cacheBytes`, `prefetchCount`; `DisplayModule.sendLoad(extra)`, `sendPrefetch`; `PiServer.loadExtras/muteFor` read the library row, the playlist row and the Settings.
- TV: `MediaCache`, `DisplayPlayer` photo mode (`ImageSlot`, clock, pause/seek/stop), `ImageStage` widget, `DisplayClient` prefetch and extras, `main_tv` opens the cache in the app support directory and sets the decoded-image budget to 160 MB. New dependency `path_provider`.
- Fixed while testing: Flutter's `precacheImage` swallows a decode error, so a broken file would have shown a broken picture; the stage now skips it.
- Decisions: a `cacheRequired` clip is downloaded by the TV when it loads (the spec says the Pi skips it until cached; the Pi has no cache report from the TV, so the TV waits instead and the previous picture stays). A duplicate in the cache for `1920` and `full` is avoided by preferring a cached full image.
- Tests: media cache (8), player photo/clip mode (12), image stage (6), prefetch through a real hub (2), Pi extras and prefetch (5 + 3).
- Not verified on the TV (to test once everything is built): EXIF rotation of full photos (Flutter is expected to apply it; the 1920 variants are already upright), wide-gamut colour on the panel, the 160 MB decode budget, cross-fade smoothness at 3840x2160, cache size on the real app storage.
