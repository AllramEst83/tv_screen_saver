---
title: 'Pi media worker'
type: 'feature'
created: '2026-11-24'
status: 'in-progress'
baseline_commit: '23c785000a8f42c94b6c9e8e40099c673e3e2221'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-fidelity.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Library items are stored but never inspected. The Pi cannot tell whether the TV can play a video, has no metadata to show, and creates no thumbnails, posters or 1920 px image variants, so the variant routes always return `404`.

**Approach:** Add a background media worker to `hub_core` that runs `ffprobe` on every video, checks it against what the TV reported in `display.capabilities` and the streaming rules, generates posters and image variants with `ffmpeg` and `libvips`, stores the metadata, and announces it with `library.updated`.

## Boundaries & Constraints

**Always:**
- Run external tools through an injectable runner (`Process.run` with an argument list, no shell, timeouts 30 s probe, 60 s image or poster, killed on timeout). One job at a time, started with low priority (`nice`) when available. The worker never blocks upload responses beyond one quick `ffprobe`.
- Schema 3 (`onUpgrade` from 2, keep all data): `LibraryItems` gains `audioCodec`, `profile`, `state` (`new|ready|unsupported|error`), `stateReason`, `cacheRequired`, `variants` (comma list). Regenerate the `.g.dart`.
- Video probe: width, height, duration, video codec and profile, HDR (`HDR10` by `smpte2084`, `HLG` by `arib-std-b67`, `DolbyVision` by DV side data, else `SDR`), fps, bitrate, audio codec. Stored on the item.
- Capability check against the stored `display.capabilities` of the display (shape as sent by the TV: `decoders[]`, `hdr[]`, `render`, `panel`): an unsupported video codec, HDR format or audio codec marks the item `unsupported` with a reason such as "HEVC Main10 is not supported by this TV; convert it on the PC". With no display having reported yet the item stays `new` and is checked when a display sends capabilities. `unsupported` items are excluded from the `all` playlist and from `player.play`, are kept on disk, and are re-checked when capabilities change.
- Streaming ceiling (setting `TVSAVER_STREAM_CEILING_MBPS`, default 80): a video whose bitrate is above it is accepted with `cacheRequired: true` (the phone shows "plays after caching"). If it is also larger than 25 % of the TV cache cap (setting `TVSAVER_TV_CACHE_BYTES`, default 2.5 GB), the upload is refused with `422 {code:"too_heavy", reason}` telling the user to lower its bitrate or size on the PC, and the file is deleted.
- Variants (JPEG, written to `mediaDir/.variants/<id>.<variant>`): video `poster` (frame at 10 % of the duration, long edge ≤ 1920) and `thumb` (long edge 320); image `1920` (long edge 1920, never upscaled, orientation applied, ICC profile embedded) and `thumb`. Skip a variant that would be as large as the source. When variants are done send `library.updated {id, …}` and refresh the item.
- Tool probe at start: missing `ffprobe`, `ffmpeg` or `vips` is logged once, items stay `new` (no variants), uploads still work. Existing library items (including the loose clips) are queued at start and when a tool becomes available.
- `packages/hub_core/tool/probe.dart <file>`: runs the worker's probe and variant steps on one file (any machine with the tools) and prints the result, so Kay can verify on the Pi.
- No mention of Drawing Aid or drawing_poc anywhere.

**Never:**
- No transcoding or re-encoding of the stored `full` file, no phone-side prep (4-3), no inbox image prep (4-5), no TV changes, no tone mapping.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| HEVC upload, TV supports it | Display reported | Item `ready`, metadata, poster and thumb, `library.updated` | — |
| Codec or HDR not supported | Display reported | Item `unsupported` with reason, not playable | Phone shows reason |
| No display yet | Never reported | Item stays `new`; checked when capabilities arrive | — |
| Above ceiling, small | bitrate > 80 Mbps, ≤ 25 % of cache | Accepted, `cacheRequired` | — |
| Above ceiling, huge | bitrate > 80 Mbps and > 25 % of cache | `422 too_heavy`, file deleted | Message to lower bitrate |
| Image upload | JPEG with orientation and ICC | `1920` and `thumb` variants keep colour | Corrupt image → `error` state |
| Rotated or P3 image | EXIF orientation 6, Display P3 | Variant upright, ICC embedded | — |
| Tool missing | No `vips` / `ffmpeg` | One log line, items `new` | Uploads unaffected |
| Tool hangs | Runs past timeout | Killed, item `error` with reason | Next job continues |
| Schema upgrade | Pi database at version 2 | Data kept, columns added | — |
| Delete during a job | Item deleted while queued | Job dropped, no stray variants | — |

</frozen-after-approval>

## Code Map

- `packages/hub_core/lib/src/db/hub_database.dart` -- `LibraryItems`, `schemaVersion` (2 → 3), `onUpgrade` (`m.addColumn`), queries; regenerate `hub_database.g.dart`.
- `packages/hub_core/lib/src/server/library_store.dart` -- upload `_finish`, `reconcile()`, `deleteItem`, `onItemRemoved`; add worker hooks (enqueue after store/import), the quick probe before `201` for the `too_heavy` refusal, `library.updated`.
- `packages/hub_core/lib/src/server/media_worker.dart` (new), `tool_runner.dart` (new, injectable), `server/display_module.dart` (stored capabilities, notify on change), `server/playlist_source.dart` (`LibraryPlaylistSource` skips `unsupported`), `server/player_module.dart` (`player.play` refuses `unsupported`), `server.dart` (variant serving exists), `config.dart` (ceiling and cache settings).
- `packages/hub_core/test/` -- worker tests with a fake runner (ffprobe JSON fixtures for SDR, HDR10, HLG, Dolby Vision, 10-bit HEVC, missing audio), real `ffprobe`/`ffmpeg` tests on small generated clips when available on the machine (skip otherwise), a schema 2 → 3 migration test.
- `packages/hub_core/tool/probe.dart` (new); `modules.md` (library item fields, `library.updated`), `BUILD_AND_DEPLOY.md` (Pi packages: `sudo apt install ffmpeg libvips-tools`, probe tool).

## Tasks & Acceptance

**Execution:**
- [ ] `hub_database.dart` + `.g.dart` -- schema 3 columns and queries
- [ ] `tool_runner.dart`, `media_worker.dart` -- probe parsing, capability and ceiling rules, variant generation, queue and timeouts
- [ ] `library_store.dart`, `display_module.dart`, playlist and player modules, `config.dart` -- hooks, rechecks on capabilities, excluding `unsupported`
- [ ] `test/**` -- every matrix row; fake-runner fixtures; real-tool tests that skip when tools are absent
- [ ] `tool/probe.dart`, docs

**Acceptance Criteria:**
- Given `dart analyze` and `dart test` in `packages/hub_core`, then both pass and the arm64 exe compiles.
- Given the tools installed, when a rotated Display P3 JPEG and an HDR10 HEVC clip are stored, then variants exist, the library shows their metadata and `library.updated` is sent, and `GET /media/<id>/thumb` returns `200` with Range support.
- Given a TV that reports no HDR10, when an HDR10 clip is stored, then it is `unsupported` with the convert-on-PC reason and `all` skips it.

## Implementation Notes

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `cd packages/hub_core && dart run build_runner build --delete-conflicting-outputs && dart analyze && dart test` -- expected: no issues, all tests pass
- `cd packages/hub_core && dart compile exe --target-os linux --target-arch arm64 bin/pi_server.dart -o build/tvsaver` -- expected: success

**Manual checks (batched with the final checklist):**
- On the Pi after `sudo apt install ffmpeg libvips-tools`: `dart`-free check by uploading a photo and a clip, then `GET` the `thumb` and `poster` variants; `tool/probe.dart` output compared with `ffprobe`.
