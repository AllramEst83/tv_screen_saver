import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart' show Value;

import '../db/hub_database.dart';
import '../protocol.dart';
import 'hub_module.dart';

/// Longest playlist name.
const kMaxPlaylistName = 60;

/// Most items one playlist holds.
const kMaxPlaylistItems = 1000;

/// A playlist as phones see it.
Map<String, Object?> playlistJson(PlaylistRow r) => {
  'id': r.id,
  'name': r.name,
  'items': _decodeItems(r.items),
  'shuffle': r.shuffle,
  'imageSeconds': r.imageSeconds,
  'transition': r.transition,
  'kenBurns': r.kenBurns,
  'muted': r.muted,
  'createdAt': r.createdAt,
  'updatedAt': r.updatedAt,
};

List<String> _decodeItems(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is List) {
      return [
        for (final e in v)
          if (e is String) e,
      ];
    }
  } catch (_) {}
  return const [];
}

/// What happened to a playlist: `playlist.changed {playlist}` or
/// `playlist.removed {id}`.
class PlaylistEvent {
  const PlaylistEvent(this.kind, this.data);

  final String kind;
  final Map<String, Object?> data;
}

/// Stored playlists: validation, persistence and change events.
class PlaylistStore {
  PlaylistStore({
    required this.db,
    required this.knownItemIds,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  final HubDatabase db;

  /// The ids of every item in the library.
  final Future<Set<String>> Function() knownItemIds;
  final DateTime Function() _now;
  final Random _random;
  final _events = StreamController<PlaylistEvent>.broadcast();

  Stream<PlaylistEvent> get events => _events.stream;

  Future<List<Map<String, Object?>>> list() async => [
    for (final r in await db.allPlaylists()) playlistJson(r),
  ];

  String _newId() {
    final hex = List.generate(
      6,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'p$hex';
  }

  static HubError _bad(String msg, [String? field]) =>
      HubError(HubErrorCode.invalid, msg, {'field': ?field});

  /// Creates a playlist from [args] (`name` is required).
  Future<Map<String, Object?>> create(Map<String, Object?> args) =>
      _write(null, args);

  /// Changes the given fields of playlist [id].
  Future<Map<String, Object?>> update(String id, Map<String, Object?> args) =>
      _write(id, args);

  Future<Map<String, Object?>> _write(
    String? id,
    Map<String, Object?> args,
  ) async {
    final old = id == null ? null : await db.playlistById(id);
    if (id != null && old == null) {
      throw const HubError(HubErrorCode.notFound, 'Unknown playlist');
    }
    var name = old?.name;
    if (args.containsKey('name') || old == null) {
      final raw = args['name'];
      name = raw is String ? raw.trim() : '';
      if (name.isEmpty || name.length > kMaxPlaylistName) {
        throw _bad('The name must be 1-$kMaxPlaylistName characters', 'name');
      }
    }
    var items = old == null ? <String>[] : _decodeItems(old.items);
    if (args.containsKey('items')) {
      final raw = args['items'];
      if (raw is! List || raw.any((e) => e is! String)) {
        throw _bad('items must be a list of ids', 'items');
      }
      items = <String>{...raw.cast<String>()}.toList();
      if (items.length > kMaxPlaylistItems) {
        throw _bad(
          'A playlist holds at most $kMaxPlaylistItems items',
          'items',
        );
      }
      final known = await knownItemIds();
      final missing = items.where((i) => !known.contains(i)).toList();
      if (missing.isNotEmpty) {
        throw _bad('Not in the library: ${missing.first}', 'items');
      }
    }
    bool flag(String key, bool current) {
      if (!args.containsKey(key)) return current;
      final v = args[key];
      if (v is! bool) throw _bad('$key must be true or false', key);
      return v;
    }

    int? seconds = old?.imageSeconds;
    if (args.containsKey('imageSeconds')) {
      final v = args['imageSeconds'];
      if (v != null && (v is! int || v < 3 || v > 120)) {
        throw _bad('Photo time must be 3-120 seconds', 'imageSeconds');
      }
      seconds = v as int?;
    }
    String? transition = old?.transition;
    if (args.containsKey('transition')) {
      final v = args['transition'];
      if (v != null && v != 'crossfade' && v != 'cut') {
        throw _bad('transition must be crossfade or cut', 'transition');
      }
      transition = v as String?;
    }
    final shuffle = flag('shuffle', old?.shuffle ?? false);
    final kenBurns = flag('kenBurns', old?.kenBurns ?? false);
    final muted = flag('muted', old?.muted ?? false);

    final now = _now().millisecondsSinceEpoch;
    final rowId = id ?? _newId();
    await db.writePlaylist(
      PlaylistsCompanion(
        id: Value(rowId),
        name: Value(name!),
        items: Value(jsonEncode(items)),
        shuffle: Value(shuffle),
        imageSeconds: Value(seconds),
        transition: Value(transition),
        kenBurns: Value(kenBurns),
        muted: Value(muted),
        createdAt: Value(old?.createdAt ?? now),
        updatedAt: Value(now),
      ),
    );
    final json = playlistJson((await db.playlistById(rowId))!);
    _events.add(PlaylistEvent('playlist.changed', {'playlist': json}));
    return json;
  }

  Future<bool> delete(String id) async {
    if (await db.deletePlaylistRow(id) == 0) return false;
    _events.add(PlaylistEvent('playlist.removed', {'id': id}));
    return true;
  }

  /// Takes a deleted library item out of every playlist.
  Future<void> forgetItem(String itemId) async {
    for (final r in await db.allPlaylists()) {
      final items = _decodeItems(r.items);
      if (!items.contains(itemId)) continue;
      items.remove(itemId);
      await db.writePlaylist(
        PlaylistsCompanion(
          id: Value(r.id),
          name: Value(r.name),
          items: Value(jsonEncode(items)),
          createdAt: Value(r.createdAt),
          updatedAt: Value(_now().millisecondsSinceEpoch),
        ),
      );
      _events.add(
        PlaylistEvent('playlist.changed', {
          'playlist': playlistJson((await db.playlistById(r.id))!),
        }),
      );
    }
  }

  /// Item ids of [id] in play order (shuffled once per edit, so the order is
  /// the same every time the player asks); null when there is no such
  /// playlist. Ids that left the library are skipped.
  Future<List<String>?> orderedIds(String id) async {
    final r = await db.playlistById(id);
    if (r == null) return null;
    final known = await knownItemIds();
    final items = [
      for (final i in _decodeItems(r.items))
        if (known.contains(i)) i,
    ];
    if (r.shuffle) items.shuffle(Random(r.updatedAt ^ r.id.hashCode));
    return items;
  }

  Future<void> dispose() => _events.close();
}
