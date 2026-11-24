---
title: 'Library and resumable uploads'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '25f2544f7e9cbb71f5ff687967e9b08d22149a98'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/modules.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/architecture.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi only serves loose files that someone copied into the media directory by hand. A phone cannot add photos or videos, nothing records what is stored, duplicates go unnoticed, and there is no storage limit (CAP-4, CAP-5).

**Approach:** Add a drift library (items and unfinished uploads), a `library` hub module, and the HTTP upload and delete routes from `media-server.md` to the Pi, with sha256 verification, resume, duplicate detection, size limits and a storage cap. Existing loose files become library items.

## Boundaries & Constraints

**Always:**
- Routes as in `media-server.md`, all behind the existing auth (static token or paired device token). `POST /media/uploads {name, bytes, sha256, mime}` → `{uploadId, received}`: `409 {id}` if the sha256 is already in the library; the same sha256 with an unfinished upload returns that upload and its `received` (resume); `413` above 80 MB (images) or 50 GB (videos); `415` for a mime that is not a supported image or video; `507 {code:"full", usedBytes, capBytes}` when the file would pass the storage cap or the disk free space.
- `PUT /media/uploads/<uploadId>` chunk with `Content-Range`: it must start at `received`, else `416` with `Content-Range: bytes */<received>`. A chunk larger than 64 MB gets `413`. `HEAD` returns `Upload-Offset: <received>`. On the last chunk the Pi hashes the file: mismatch → delete the partial, `422`; match → move it into the library, `201 {id, name, kind, bytes, sha256}` and broadcast `library.added`. Unfinished uploads older than 24 h are deleted (at start and hourly).
- New item ids are `<first 16 hex of sha256>.<ext>` (matches `_idPattern`). Files live at `mediaDir/<id>`; variants at `mediaDir/.variants/<id>.<variant>`. `GET /media/<id>/<variant>`: `full` as today; `thumb`, `poster`, `1920` serve the variant file when it exists (Range/206), else `404` (the worker is story 4-2).
- `DELETE /media/<id>`: owner only (`403` otherwise, static token counts as owner), removes row, file and variants, broadcasts `library.removed`, `404` if unknown.
- Drift: new tables `LibraryItems {id, kind, name, sha256 unique, bytes, width, height, durationMs, codec, hdr, fps, bitrate, createdAt}` and `Uploads {id, name, bytes, sha256, mime, received, deviceId, createdAt}`; schema version 2 with a real `onUpgrade` from 1 that keeps devices and pairings (the Pi already runs version 1). Regenerate the `.g.dart`.
- Startup import: every loose servable file in `mediaDir` without a row gets one (id = file name, sha256 computed in the background, kind from extension, name = file name); files of other kinds and `*.bin` are skipped.
- `library` module: `library.exists {sha256}` → `{exists, id?}`; `library.rename {id, name}` (any paired device); `library.delete {id}` (owner only); events `library.added`, `library.updated`, `library.removed`; snapshot `{items[], storage:{usedBytes, capBytes}}`. Storage cap from `ServerConfig` (`TVSAVER_STORAGE_CAP_BYTES`, default 90 GB). Nothing is deleted silently.
- The `all` playlist becomes the library's video items sorted by name (case-insensitive); player behaviour is unchanged.
- `packages/hub_core/tool/upload.dart`: dev uploader (`dart run tool/upload.dart <file> --host … --token …`) that shows progress, resumes after an interruption, and reports duplicate and checksum results.
- No mention of Drawing Aid or drawing_poc anywhere.

**Never:**
- No ffprobe, image variants or posters (4-2), no phone prep or upload UI (4-3), no playlist editing (4-4), no inbox watcher (4-5), no TV changes, no TLS, no uploads by a display device.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| New upload | `POST`, chunks, last chunk | `201`, row, file `mediaDir/<id>`, `library.added` | — |
| Duplicate | sha256 already stored | `409 {id}` before any transfer | — |
| Resume | `HEAD`, then `PUT` from offset | Completes with matching sha256 | Wrong offset → `416` + current offset |
| Bad checksum | Data differs from declared sha256 | Partial deleted, `422` | — |
| Too large | image > 80 MB / video > 50 GB | `413` at `POST` | Oversize chunk → `413` |
| Storage full | Would pass cap or free space | `507 {code:"full", usedBytes, capBytes}` | Nothing deleted |
| Unsupported type | mime not image/video | `415` | — |
| Stale upload | Older than 24 h | Partial and row removed | — |
| Delete | Controller / owner `DELETE /media/<id>` | `403` / `200`, `library.removed` | Unknown → `404` |
| Upgrade | Pi database at version 1 | Devices and pairings kept, new tables added | — |
| Legacy files | Clips already in `mediaDir` | Become items, `all` playlist unchanged | Skipped kinds ignored |
| Serve | `GET /media/<id>/full` with Range | `206` as in 2-2; missing variant → `404` | — |

</frozen-after-approval>

## Code Map

- `packages/hub_core/lib/src/db/hub_database.dart` -- add tables and queries, `schemaVersion = 2`, `onUpgrade` (`m.createTable`), keep `PRAGMA foreign_keys`; `hub_database.g.dart` regenerated with `dart run build_runner build --delete-conflicting-outputs`.
- `packages/hub_core/lib/src/server.dart` -- `PiServer._handle` routes `POST/PUT/HEAD /media/uploads…`, `DELETE /media/<id>`, variant serving in `_serveFile`; reuse `parseRange`, `contentTypeFor`, `constantTimeEquals`, `hub.authenticateHttp` (device role for owner checks).
- `packages/hub_core/lib/src/server/library_module.dart` (new, follow `DevicesModule`/`PlayerModule`), `library_store.dart` (new: upload state, hashing, import, expiry); `playlist_source.dart` (`LibraryPlaylistSource`, replaces `MediaDirPlaylistSource` as `PiServer` default); `config.dart` (storage cap); `lib/hub_core.dart` exports.
- `packages/hub_core/test/` -- HTTP tests against `PiServer` with temp dirs, module tests with the existing fake phone harness, a migration test that builds a version 1 database file first.
- `packages/hub_core/tool/upload.dart` (new); `BUILD_AND_DEPLOY.md` and `modules.md` (library snapshot and events).

## Tasks & Acceptance

**Execution:**
- [x] `hub_database.dart` + `.g.dart` -- tables, queries, schema 2, `onUpgrade`
- [x] `library_store.dart`, `server.dart` -- upload, resume, verify, expiry, delete, variants, caps, startup import
- [x] `library_module.dart`, `playlist_source.dart`, `config.dart`, exports -- module, library-backed `all`, cap setting
- [x] `test/**` -- every matrix row; resume across a server restart; upgrade from a real version 1 file
- [x] `tool/upload.dart`, docs -- dev uploader, `modules.md`, `BUILD_AND_DEPLOY.md`

**Acceptance Criteria:**
- Given `dart analyze` and `dart test` in `packages/hub_core`, then both pass and `dart compile exe bin/pi_server.dart` succeeds.
- Given a 4 GB file uploaded with the dev tool and interrupted at 40 %, when it is resumed, then it finishes with a matching sha256 and appears in `library.added`; uploading it again returns `409` before any bytes are sent.
- Given the Pi running 3-4 with its version 1 database, when the new server starts, then pairings still work, the five staged clips are library items, and the phone's Play still plays them.

## Implementation Notes

- Schema 2 adds `LibraryItems` and `Uploads` (upgrade from 1 keeps devices and pairings). `all` is the library's video items; a throttled `reconcile()` (start, hourly, before the playlist answers) imports hand-copied files (skips files younger than 10 s) and prunes rows whose file is gone, until the 4-5 inbox watcher. Last chunk verifies from a running sha256; a restart falls back to one disk rehash. Deleting the playing item moves the player on. Display tokens may delete (owner-equivalent). Storage cap is decimal bytes. Disk-full to 507 is untested (cannot provoke it). Not run on the real Pi: the 4 GB interrupt-and-resume check and the version 1 database upgrade.

## Spec Change Log

## Review Triage Log

| Finding | Verdict | Route | Evidence |
| --- | --- | --- | --- |
| Concurrency: HEAD/resume POST truncates a part file under an active PUT; stale row read before the busy lock; two POSTs with one sha256 hit the unique constraint (500); concurrent POSTs pass the cap together | high | patch | `_syncReceived`, `putChunk`, `startUpload` as filed by edge and blind hunters |
| Last chunk hashes the whole file in the request (tens of seconds to minutes for GBs on the Pi) | medium | patch | `_finish` re-reads the file; hash incrementally while chunks arrive |
| `_finish` renames before the DB commit (orphan file, stale upload row); 16-hex id collision can overwrite another file | medium | patch | rename then transaction |
| Only `UploadRefused` maps to a status; disk-full, body abort, DB errors and oversize POST body give unspecified errors | medium | patch | `_handleUploads` catch scope |
| New files copied into the media dir (the scp workflow from 2-3) do not appear in `all` until restart; rows of hand-removed files stay and fail to play; files still being copied imported early | high | patch | Regression vs 3-4: `MediaDirPlaylistSource` listed live |
| Deleting the playing or queued item leaves the player on a stale id | medium | patch | `deleteItem` does not notify `PlayerModule` |
| Duplicate loose file stays `pending:` forever and is re-hashed every start | medium | patch | `_hashPending` `continue` |
| Delete: variant sweep by prefix can hit another item's variants; row deleted before file | low | patch | `startsWith('$id.')` |
| Mime with parameters gets 415; ids starting with `.` reachable on `/media`; cap env accepts 0/negative/garbage, in-flight uploads not counted, unit undocumented; hash loop dies on one unreadable file; part file deleted by expiry between create and insert | low | patch | Small guards |
| `tool/upload.dart`: 416 loop without progress, non-int `received` | low | patch | Dev tool on the manual-test path |
| Missing tests: crash-recovery in `startUpload` (three branches), env cap, display delete via HTTP and module, new concurrency and reconcile paths | medium | patch | Verification-gap evidence |
| Display token may delete (HTTP and module) vs "owner only" | low | patch (doc + test) | Display is owner-equivalent by architecture; pin it |
| Expiry keyed on `createdAt`, not last activity | low | reject | Matches the spec text; a 50 GB upload takes well under 24 h |
| Mime trusted, no content sniffing; `/media` not gated on a row; schema rollback; paging; audit; revoked token during a PUT; PNG/WebP sniff and HEAD variant tests; `LibraryPlaylistSource` fallback test | low | reject | No named harm in this story; sniffing is 4-2 |
| Story file status/checkboxes empty | false | reject | Workflow updates the story after review |

## Verification

**Commands:**
- `cd packages/hub_core && dart run build_runner build --delete-conflicting-outputs && dart analyze && dart test` -- expected: no issues, all tests pass
- `cd packages/hub_core && dart compile exe --target-os linux --target-arch arm64 bin/pi_server.dart -o build/tvsaver` -- expected: success

**Manual checks:**
- Kay deploys the server, runs `tool/upload.dart` on a large file, kills it halfway, resumes it, and checks the item plays from the phone.
