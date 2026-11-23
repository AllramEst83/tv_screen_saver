# Media fidelity (CAP-2, CAP-3, CAP-4, CAP-9)

Adapted from Drawing Aid (`../drawing_poc`: `lib/tv/display_report.dart`, `lib/phone/images/image_prep.dart`, spec `image-fidelity.md`). Rule: picture quality wins every trade-off.

## Measure first

- Copy `DisplayReport`: the Flutter view's `physicalSize` and `devicePixelRatio` vs `view.display.size`. Show it in the TV's About screen and log it at startup (`DisplayReport: renders …, panel …`). Also send it in `display.capabilities`.
- Phase 1: the spike app plus `tool/tv/display_report.sh` (`adb shell wm size`, `adb shell dumpsys display`). Kay runs it on the X90K; the result is logged in the spec memlog.
- If it reads "below the panel" (1080p render), the **native 4K image path is required** (phase 5): images are shown on a hardware surface at 3840×2160, not through the Flutter UI plane. Video is unaffected because it already uses the SurfaceView path.

## Video

- Play on a hardware `SurfaceView`, not a Flutter texture. Use `video_player` with `VideoViewType.platformView` if the installed version supports it, otherwise a Media3 `PlayerView` embedded as a platform view.
- Phase 1 test: the same 4K clip with 1 px line pairs in texture vs platform-view mode on the X90K. Record which one shows full detail.
- **HDR:** HDR10, HLG and Dolby Vision are passed through untouched; the TV switches mode itself. No tone mapping in the app.
- **Frame rate:** the X90K exposes only a 3840×2160 @ 60 Hz display mode (measured in phase 1), so the app cannot match the refresh rate to the content. It plays frames at native timing with Media3's default frame-rate strategy and does no conversion of its own. The TV may still apply its own film-motion handling.
- Auth: `Authorization: Bearer` via the player's HTTP headers.
- Recommended files: HEVC Main10, 3840×2160, ≤ 60 fps, HDR10/HLG/Dolby Vision or SDR, 40–80 Mbps, MP4/MKV. On upload or import, the Pi checks with `ffprobe` that codec, profile/level and HDR format are in the TV's `display.capabilities`. If not, the item is rejected with a message telling the user to convert it on the PC. If no display has reported yet, the item is accepted and checked when one does.
- **Audio:** the video's sound plays by default. The audio track passes through untouched (AAC, AC-3, E-AC-3, Dolby Atmos); `ffprobe` checks the audio codec against `display.capabilities` too.
- **Seamless loop:** a single looping video (e.g. a fireplace) repeats with no black frame and no audio gap or click at the loop point (Media3 repeat mode, pre-buffered).
- **Loop:** Media3 repeat-one is the loop strategy (no gap heard on the X90K in phase 1). Gapless playlists: prepare the next item's player before the current one ends, then cut or crossfade.

## Images: upload (phone and inbox)

- Pickers get the original file (no `maxWidth`, `maxHeight`, `imageQuality`).
- Long edge ≤ 4096 px (the panel is 3840). Larger images are downscaled with an area-average filter and encoded once at JPEG q95.
- A JPEG ≤ 4096 px is sent **without re-encoding**, rotated or not. Kept byte-wise: the ICC colour profile and the EXIF orientation tag. Stripped byte-wise: GPS and other EXIF, XMP, comments, maker notes, Ultra HDR gain maps.
- PNG stays PNG. Prep runs in an isolate. Images over 64 MP are refused before decoding.
- Inbox images get the same rules, applied on the Pi with libvips.

## Images: storage (Pi)

- The Pi stores `full` as uploaded, plus generated `1920` (long edge) and `thumb` variants (libvips, orientation and ICC applied). Variants are generated in the background, and `library.updated` fires when they're ready.

## Images: decode and render (TV)

- The TV downloads `full` when the render surface (Flutter or native 4K path) is ≥ 3840 px wide, otherwise `1920`.
- It applies the EXIF orientation and decodes in the embedded colour space (wide gamut kept, not flattened to sRGB).
- It decodes at the displayed size (`cacheWidth`/`cacheHeight` = on-screen pixels), never above the stored size.
- Decoded RGBA budget: ≤ 160 MB (current + next image + transition). Tune it on the device.
- One decode at a time, newest request wins. The next image is decoded before its transition starts. The current image stays on screen until the next one is ready.
- Draw with `FilterQuality.high`. Default transition: crossfade. Ken Burns is off by default (resampling softens the image); when on, pan/zoom is a GPU `Transform`, never a re-decode per frame.

## Verification

- Test chart: 4000×3000 with 1 px line pairs and a gradient. After upload, the stored file vs the original resized to the same size has PSNR ≥ 40 dB. A JPEG ≤ 4096 px has pixel data identical to the original, including a rotated one.
- Colour: a Display P3 test image keeps its ICC profile after upload and shows the same colours on the TV as on the source device.
- On the TV, the line pairs resolve at 3840×2160 on the panel, with no 8×8 block artefacts in the gradient.
- Video: HDR10, HLG and Dolby Vision test clips trigger the matching TV HDR badge. A 23.976 fps pan shows no objectionable judder by eye. A 10-minute fireplace clip looped for 1 h plays its sound with no audible gap or click at the loop point.
- 30-minute slideshow of 24 MP photos: within the decode budget, no OOM, no stall.
