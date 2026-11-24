/// What the TV is playing, from the Pi's `player` snapshot and
/// `player.changed` events.
class NowPlaying {
  const NowPlaying({
    this.playlistId,
    this.index = 0,
    this.itemId,
    this.state = 'idle',
    this.positionMs = 0,
    this.startedAt,
    this.muted = false,
  });

  final String? playlistId;
  final int index;
  final String? itemId;

  /// `idle`, `playing` or `paused`.
  final String state;

  /// Position when the state last changed.
  final int positionMs;

  /// Pi time at which position 0 was (or would have been); set while playing.
  final int? startedAt;
  final bool muted;

  bool get isIdle => itemId == null || state == 'idle';
  bool get isPlaying => state == 'playing' && itemId != null;

  /// The position now, given the Pi's clock ([piNowMs], see
  /// `HubClient.tvNowMs`). Never negative.
  int positionAt(int piNowMs) {
    final start = startedAt;
    if (!isPlaying || start == null) return positionMs;
    final pos = piNowMs - start;
    return pos < 0 ? 0 : pos;
  }

  static NowPlaying? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final state = raw['state'];
    return NowPlaying(
      playlistId: raw['playlistId'] as String?,
      index: (raw['index'] as num?)?.toInt() ?? 0,
      itemId: raw['itemId'] as String?,
      state: state is String ? state : 'idle',
      positionMs: (raw['positionMs'] as num?)?.toInt() ?? 0,
      startedAt: (raw['startedAt'] as num?)?.toInt(),
      muted: raw['muted'] == true,
    );
  }
}

/// `1:05` or `1:02:03`.
String formatPosition(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
