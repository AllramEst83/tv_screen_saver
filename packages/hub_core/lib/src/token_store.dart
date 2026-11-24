
/// Saved pairing record for a Drawing Aid TV, keyed by [hubId].
class SavedHubPairing {
  const SavedHubPairing({
    required this.hubId,
    required this.token,
    required this.lastHost,
    required this.lastPort,
    required this.hubName,
    this.label,
  });

  final String hubId;
  final String token;
  final String lastHost;
  final int lastPort;
  final String hubName;

  /// Local label chosen on this phone; the TV's own name is [hubName].
  final String? label;

  /// What the phone shows for this TV.
  String get displayName =>
      (label != null && label!.trim().isNotEmpty) ? label!.trim() : hubName;

  SavedHubPairing copyWith({
    String? token,
    String? lastHost,
    int? lastPort,
    String? hubName,
    String? label,
    bool clearLabel = false,
  }) => SavedHubPairing(
    hubId: hubId,
    token: token ?? this.token,
    lastHost: lastHost ?? this.lastHost,
    lastPort: lastPort ?? this.lastPort,
    hubName: hubName ?? this.hubName,
    label: clearLabel ? null : (label ?? this.label),
  );
}

abstract class HubTokenStore {
  Future<SavedHubPairing?> getPairing(String hubId);
  Future<SavedHubPairing?> getLastPairing();
  Future<void> savePairing(SavedHubPairing pairing);
  Future<void> removePairing(String hubId);

  /// Every stored pairing, oldest id first.
  Future<List<SavedHubPairing>> allPairings();

  /// Makes [hubId] the TV [getLastPairing] returns.
  Future<void> setActive(String hubId);

  /// Sets or clears (null or blank) the local label of a stored pairing.
  Future<void> setLabel(String hubId, String? label);
}


/// In-memory token store for unit and integration tests.
class MemoryHubTokenStore implements HubTokenStore {
  final Map<String, SavedHubPairing> _pairings = {};
  String? _lastId;

  @override
  Future<SavedHubPairing?> getPairing(String hubId) async => _pairings[hubId];

  @override
  Future<SavedHubPairing?> getLastPairing() async =>
      _lastId == null ? null : _pairings[_lastId];

  @override
  Future<void> savePairing(SavedHubPairing pairing) async {
    final old = _pairings[pairing.hubId];
    _pairings[pairing.hubId] = pairing.label == null && old?.label != null
        ? pairing.copyWith(label: old!.label)
        : pairing;
    _lastId = pairing.hubId;
  }

  @override
  Future<List<SavedHubPairing>> allPairings() async => [
    for (final k in _pairings.keys.toList()..sort()) _pairings[k]!,
  ];

  @override
  Future<void> setActive(String hubId) async {
    if (_pairings.containsKey(hubId)) _lastId = hubId;
  }

  @override
  Future<void> setLabel(String hubId, String? label) async {
    final p = _pairings[hubId];
    if (p == null) return;
    final blank = label == null || label.trim().isEmpty;
    _pairings[hubId] = blank
        ? p.copyWith(clearLabel: true)
        : p.copyWith(label: label.trim());
  }

  @override
  Future<void> removePairing(String hubId) async {
    _pairings.remove(hubId);
    if (_lastId == hubId) {
      _lastId = (_pairings.keys.toList()..sort()).firstOrNull;
    }
  }
}
