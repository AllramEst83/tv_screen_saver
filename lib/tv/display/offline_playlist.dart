/// One entry of the playlist the Pi gave the TV for offline play.
class OfflineItem {
  const OfflineItem({
    required this.id,
    required this.isImage,
    this.name,
    this.cacheRequired = false,
  });

  final String id;
  final bool isImage;
  final String? name;
  final bool cacheRequired;
}

/// The current playlist as the TV last heard it (`display.playlist`): enough
/// to keep looping what is cached when the Pi cannot be reached.
class OfflinePlaylist {
  const OfflinePlaylist({
    required this.playlistId,
    required this.items,
    this.imageMs,
    this.crossfade = true,
    this.kenBurns = false,
  });

  final String playlistId;
  final List<OfflineItem> items;
  final int? imageMs;
  final bool crossfade;
  final bool kenBurns;

  /// Position of [itemId] in the list, or -1.
  int indexOf(String itemId) => items.indexWhere((i) => i.id == itemId);

  /// Null when [msg] is not a usable `display.playlist` frame.
  static OfflinePlaylist? tryParse(Map<String, dynamic> msg) {
    final id = msg['playlistId'];
    final raw = msg['items'];
    if (id is! String || id.isEmpty || raw is! List) return null;
    final items = <OfflineItem>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final itemId = e['id'];
      final kind = e['kind'];
      if (itemId is! String || itemId.isEmpty || kind is! String) continue;
      final name = e['name'];
      items.add(
        OfflineItem(
          id: itemId,
          isImage: kind == 'image',
          name: name is String ? name : null,
          cacheRequired: e['cacheRequired'] == true,
        ),
      );
    }
    return OfflinePlaylist(
      playlistId: id,
      items: items,
      imageMs: (msg['imageMs'] as num?)?.toInt(),
      crossfade: msg['transition'] != 'cut',
      kenBurns: msg['kenBurns'] == true,
    );
  }
}
