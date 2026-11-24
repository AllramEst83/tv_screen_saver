import 'dart:io';

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

/// Extensions that are in the media directory but are not media: the 1 GiB
/// throughput test file of story 2-3.
const _skippedExtensions = {'.bin'};

/// The `all` playlist: the files of the Pi media directory, sorted by name.
///
/// Reads the directory on every call, so a file added or removed shows up at
/// the next command. Hidden files, sub-directories, links and names the media
/// route would refuse are skipped.
class MediaDirPlaylistSource implements PlaylistSource {
  MediaDirPlaylistSource(this.mediaDir);

  final String mediaDir;

  @override
  Future<List<String>?> itemIds(String playlistId) async {
    if (playlistId != kAllPlaylistId) return null;
    final dir = Directory(mediaDir);
    if (!await dir.exists()) return const [];
    final names = <String>[];
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final segments = e.uri.pathSegments.where((s) => s.isNotEmpty);
        if (segments.isEmpty) continue;
        final name = segments.last;
        if (name.startsWith('.') || !_servableId.hasMatch(name)) continue;
        final dot = name.lastIndexOf('.');
        if (dot > 0 && _skippedExtensions.contains(name.substring(dot))) {
          continue;
        }
        names.add(name);
      }
    } on FileSystemException {
      return const [];
    }
    names.sort();
    return names;
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
