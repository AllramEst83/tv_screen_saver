---
title: 'Native 4K image path'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '6557470'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** The X90K renders Flutter at 1080p (memlog, 2026-11-23: "renders 1920x1080, panel 3840x2160"), so a photo through the Flutter plane loses half its resolution.

**Approach:** Draw photos on the video SurfaceView with its buffer fixed at 3840x2160. Contract: `modules.md` "Native 4K photos (story 5-3)". No TV setting is changed (no `wm size`); this works around the 1080p plane.

## Implementation Notes

- Native: `ImageSurface.kt` and `m3ShowImage` in `VideoSpike.kt`; `m3Release` blanks and restores the layout size. Dart: `DisplayVideoNative.showImage`, `DisplayPlayer.nativeImages`, re-show after the menu, `_photoShown`. `DisplayClient` enables it from the capabilities and then asks for `full`.
- The Flutter widget stays as the fallback (older Android, no surface, a TV that renders at 4K).
- Tests: native photo path in the player (7), client choice from capabilities (2). The TV release APK builds with the Kotlin.
- Not verified, and it is the part that most needs the TV: that the fixed buffer really reaches the panel at 3840x2160 (look at the 1 px line-pair chart of `media-fidelity.md`), cross-fade smoothness at 60 fps, memory with two 33 MB bitmaps, hardware canvas on Android 11/12, blanking when a clip starts. If any of these misbehaves the Flutter fallback can be forced by `nativeImages = false`.
