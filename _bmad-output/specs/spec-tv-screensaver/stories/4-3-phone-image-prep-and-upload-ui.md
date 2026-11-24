---
title: 'Phone image prep and upload UI'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '9c5f17b'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-fidelity.md'
  - '{project-root}/_bmad-output/specs/spec-tv-screensaver/media-server.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The Pi can store uploads (4-1) but the phone has no way to add a photo, and a straight upload of a phone photo would carry GPS and other private metadata or exceed the TV's 4096 px limit.

**Approach:** A Library screen in the drawer with an "Add photos" button. Each picked image is prepared on the phone (≤ 4096 px, no re-encode for a fitting JPEG, ICC colour profile and EXIF orientation kept, all other metadata removed byte-wise), checked against the library by sha256, then uploaded in resumable chunks with progress, retry and a duplicate message.

## Boundaries & Constraints

**Always:**
- Pickers return the original file (no resize or quality options). Prep runs in an isolate. Source images over 64 MP are refused before decoding.
- JPEG with long edge ≤ 4096: bytes sent unchanged except removed segments; **kept** JFIF, ICC (APP2 `ICC_PROFILE`), Adobe APP14 and the EXIF orientation value (a minimal EXIF segment holding only Orientation, when it was not 1); **removed** GPS and all other EXIF, XMP, IPTC, comments, maker notes, MPF and anything after the end-of-image marker (Ultra HDR gain maps).
- Larger images: downscaled once with an area-average filter to a 4096 px long edge, orientation applied to the pixels (so the orientation tag is dropped), ICC kept, encoded once at JPEG q95. PNG stays PNG (ICC kept, text chunks dropped; alpha kept); a PNG over 80 MB is refused with a plain message.
- Upload: `library.exists` first (known → "Already in the library", nothing sent); `POST /media/uploads {name, bytes, sha256, mime}`; `409 {id}` counts as already there; `received` from the answer is the resume offset; chunks of 8 MB by `PUT` with `Content-Range`; `416` re-syncs to the offset the Pi names. Final `201` → done. `413`, `415`, `422`, `507` and `401` give plain messages ("Too large for the Pi", "Not a supported picture", "Damaged on the way, try again", "The Pi is full", "This phone is no longer paired"). Anything else, or a lost link, → "Upload failed" with a Retry button that resumes from the Pi's offset. Uploads run one at a time. The queue stays when the user leaves the screen.
- Only owner and controller phones upload; all of this works with the TV off.
- **Library screen** (drawer entry "Library", between Now playing and Devices): header with used / cap storage bar, the upload queue (name, status, progress, Retry, Clear finished) and the stored items (name, Photo/Video, size, and for videos "needs caching" or the unsupported reason when the Pi says so). Empty state explains how to add photos. Large touch targets, 360 dp and 200 % text safe, no jargon.
- Share-to-app intake and video upload are out of scope.

**Never:**
- No GPS or other metadata leaves the phone. No upload by TV. No server changes. No mention of Drawing Aid or drawing_poc.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
| --- | --- | --- | --- |
| Fitting JPEG | 4000×3000 with GPS and ICC | Same pixel data, ICC and orientation kept, GPS gone | — |
| Rotated JPEG | Orientation 6 | Orientation 6 still in the output | — |
| Big JPEG | 6000×4000 | 4096×2731 q95 JPEG, ICC kept | — |
| PNG | alpha PNG | PNG with alpha | > 80 MB refused |
| Not an image | text file | Failed: "That file isn't a picture" | — |
| Duplicate | sha256 in library | "Already in the library", no bytes sent | — |
| Interrupted | link drops mid-chunk | Failed, Retry continues from the Pi's offset | — |
| Pi full | 507 | "The Pi is full" | — |

</frozen-after-approval>

## Code Map

- `lib/phone/images/image_header.dart`, `jpeg_strip.dart`, `image_prep.dart` (new; adapted from drawing_poc, orientation/ICC rules differ), `lib/phone/upload/uploader.dart` (new; drawing_poc's queue, now `/media/uploads` and chunked).
- `lib/phone/screens/library_screen.dart` (new), `app_shell.dart` (`buildDestinations` adds Library), `phone_controller.dart` (library item list + `uploader`), `main_phone.dart` (picker wiring).
- `packages/hub_core` `HubClient.openAuthorized` is reused; no hub_core changes.
- `pubspec.yaml`: `image`, `image_picker`, `crypto`.
- Tests: `test/phone/image_prep_test.dart`, `uploader_test.dart` (against a real `HubServer`), `library_screen_test.dart`.

## Tasks & Acceptance

**Execution:**
- [ ] image prep + jpeg strip + tests -- the privacy and fidelity core
- [ ] uploader + tests against a real server -- resume, duplicate, errors
- [ ] controller list, Library screen, drawer entry, picker wiring + tests
- [ ] docs (`modules.md` none; `BUILD_AND_DEPLOY.md` note)

**Acceptance Criteria:**
- Given the analyze and test suites, then all pass.
- Given a JPEG with GPS, when prepared, then the output has no GPS, keeps ICC, and its entropy-coded data equals the source's.
- Given a dropped link mid-upload, when Retry is pressed, then the Pi's stored file has the right sha256 and only the missing bytes were sent.

## Implementation Notes

- Added `lib/phone/images/{image_header,jpeg_strip,image_prep}.dart`, `lib/phone/upload/uploader.dart`, `lib/phone/screens/library_screen.dart`; `PhoneController` gained `libraryItems`, `canUpload` and a long-lived `uploader`; the drawer has Library.
- The `image` decoder applies EXIF rotation itself, so reported sizes are the upright ones. A fitting JPEG is rewritten byte-wise: JFIF, ICC and Adobe APP14 kept, EXIF replaced by a minimal block with only Orientation (omitted when upright); scaled images get the rotation baked into pixels.
- Mid-upload chunks answer `200 {received}`, the last `201`; `416` re-syncs to the offset in `Content-Range: bytes */N`.
- Checks: analyze clean, 178 phone tests (new: image prep, uploader against a real `PiServer`, Library screen), phone debug and TV release APKs build. Not tried on a real phone and Pi: picker, ICC colour on the TV, a 4 GB-class resume.
- Not done: video upload from the phone, share-to-app intake, thumbnails in the list (need authorised image loading; arrives with the TV/phone variant work).

## Spec Change Log

## Review Triage Log
