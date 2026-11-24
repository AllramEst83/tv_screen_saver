---
title: 'Playlists'
type: 'feature'
created: '2026-11-24'
status: 'done'
baseline_commit: '7175395'
route: 'dispatch'
review_loop_iteration: 0
---

## Intent

**Problem:** The only thing the player can play is `all`; there is no way to choose items or order.

**Approach:** A `playlist` Pi module with persisted playlists (drift schema 5), a stored-playlist source for the player, and a Playlists screen on the phone with an editor (name, items from the library with drag ordering, shuffle, mute, Ken Burns, photo time, transition).

Contract: see `modules.md` "Playlists (story 4-4)".

## Implementation Notes

- Pi: `playlist_store.dart` (validation, events, stable seeded shuffle), `playlist_module.dart`, `StoredPlaylistSource` in `playlist_source.dart`, wiring in `server.dart` (a library delete also cleans playlists). Schema 5 `Playlists`; the three upgrade tests now expect 5.
- Phone: `PhoneController` playlists, `savePlaylist`, `deletePlaylist`, `playPlaylist`; `playlists_screen.dart`; drawer entry Playlists.
- Tests: `playlist_test.dart` (8), a widget test for create, refuse, rename and delete.
- Fixed while testing: the two dropdowns overflowed at narrow width (`isExpanded`).
- Not done: TV use of the per-playlist display options (4-6, 5-1); playing a playlist on a real TV; arm64 compile and release APKs were not re-run after this story.
