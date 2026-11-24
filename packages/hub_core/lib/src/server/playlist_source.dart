import 'dart:io';

import 'library_store.dart';

/// The one playlist that exists until the playlist module (story 4-4) takes
/// over: every file in the media directory, sorted by name.
const kAllPlaylistId = 'all';

/// Where the player module gets the ordered item ids of a playlist from.
///
/// Item ids are media ids (the file name in the media directory), the same
/// ids `GET /media/<id>/full` serves.
abstract interface class PlaylistSource {
  /// The item ids of [playlistId] in play order; null when there is no such
  /// playlist. An existing playlist may be empty.
  Future<List<String>?> itemIds(String playlistId);
}

final _servableId = RegExp(r'^[A-Za-z0-9._-]+$');

/// The video files the TV can stream (lower case, with the dot).
const _videoExtensions = {'.mp4', '.m4v', '.mov', '.mkv', '.webm', '.ts'};

/// The `all` playlist: the video files of the Pi media directory, sorted by
/// name (ignoring case).
///
/// Reads the directory on every call, so a file added or removed shows up at
/// the next command. Hidden files, sub-directories, links, names the media
/// route would refuse and files that are not video are skipped. If the
/// directory cannot be listed the last good result is returned (the error is
/// thrown when there is none yet), so a hiccup never empties the playlist.
class MediaDirPlaylistSource implements PlaylistSource {
  MediaDirPlaylistSource(
    this.mediaDir, {
    Stream<FileSystemEntity> Function(Directory dir)? list,
  }) : _list = list ?? ((d) => d.list(followLinks: false));

  final String mediaDir;
  final Stream<FileSystemEntity> Function(Directory dir) _list;
  List<String>? _last;

  @override
  Future<List<String>?> itemIds(String playlistId) async {
    if (playlistId != kAllPlaylistId) return null;
    final dir = Directory(mediaDir);
    final names = <String>[];
    try {
      if (!await dir.exists()) return _last = const [];
      await for (final e in _list(dir)) {
        if (e is! File) continue;
        final segments = e.uri.pathSegments.where((s) => s.isNotEmpty);
        if (segments.isEmpty) continue;
        final name = segments.last;
        if (name.startsWith('.') || !_servableId.hasMatch(name)) continue;
        final dot = name.lastIndexOf('.');
        if (dot <= 0 ||
            !_videoExtensions.contains(name.substring(dot).toLowerCase())) {
          continue;
        }
        names.add(name);
      }
    } on FileSystemException {
      final last = _last;
      if (last != null) return List.of(last);
      rethrow;
    }
    names.sort((a, b) {
      final c = a.toLowerCase().compareTo(b.toLowerCase());
      return c != 0 ? c : a.compareTo(b);
    });
    return _last = names;
  }
}

/// The `all` playlist from the library: its video items sorted by name
/// (ignoring case). If the database cannot be read the last good list is
/// used.
class LibraryPlaylistSource implements PlaylistSource {
  LibraryPlaylistSource(this.store);

  final LibraryStore store;
  List<String>? _last;

  @override
  Future<List<String>?> itemIds(String playlistId) async {
    if (playlistId != kAllPlaylistId) return null;
    try {
      return _last = await store.videoIds();
    } catch (_) {
      final last = _last;
      if (last != null) return List.of(last);
      rethrow;
    }
  }
}

/// Fixed playlists held in memory (tests and the fake display tool).
class StaticPlaylistSource implements PlaylistSource {
  StaticPlaylistSource(Map<String, List<String>> playlists)
    : playlists = {for (final e in playlists.entries) e.key: List.of(e.value)};

  /// Edit between commands to simulate a library change.
  final Map<String, List<String>> playlists;

  @override
  Future<List<String>?> itemIds(String playlistId) async {
    final p = playlists[playlistId];
    return p == null ? null : List.of(p);
  }
}
