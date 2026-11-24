/// Estimates `tvNow - phoneNow` from ping/pong round trips.
///
/// For a pong received at `receivedAt` for a ping sent at `sentTs`, the round
/// trip is `rtt = receivedAt - sentTs` and the TV clock was read about halfway,
/// so `offset = tvNow + rtt / 2 - receivedAt`. The sample with the lowest rtt
/// among the last [maxSamples] wins, because it carries the least queueing
/// delay.
class ClockOffsetEstimator {
  ClockOffsetEstimator({this.maxSamples = 5});

  final int maxSamples;
  final List<({int rtt, int offset})> _samples = [];
  int? _provisional;

  /// Best current offset in milliseconds (0 until any sample arrives).
  int get offsetMs {
    if (_samples.isEmpty) return _provisional ?? 0;
    var best = _samples.first;
    for (final s in _samples) {
      if (s.rtt < best.rtt) best = s;
    }
    return best.offset;
  }

  bool get hasSamples => _samples.isNotEmpty;

  /// Offset from a frame without an echoed timestamp (`ready`, `snapshot`).
  /// Ignored once a real round-trip sample exists.
  void setProvisional(int tvNow, int phoneNow) {
    _provisional = tvNow - phoneNow;
  }

  void addSample({
    required int sentTs,
    required int receivedAt,
    required int tvNow,
  }) {
    final rtt = receivedAt - sentTs;
    if (rtt < 0) return;
    final offset = (tvNow + rtt / 2 - receivedAt).round();
    _samples.add((rtt: rtt, offset: offset));
    if (_samples.length > maxSamples) _samples.removeAt(0);
  }

  void reset() {
    _samples.clear();
    _provisional = null;
  }
}
