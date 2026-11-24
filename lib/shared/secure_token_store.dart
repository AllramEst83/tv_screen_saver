import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hub_core/hub_core.dart';

/// [HubTokenStore] backed by `flutter_secure_storage` (Android Keystore).
///
/// All pairings live in one JSON entry so a read or write is atomic. Writes
/// are serialised: the hub client saves pairings without awaiting them.
class SecureTokenStore implements HubTokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 'tvsaver.pairings.v1';

  final FlutterSecureStorage _storage;
  Future<void> _queue = Future.value();

  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _queue.then((_) => body());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<_Data> _read() async {
    final String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } catch (_) {
      // Keystore failure (e.g. a restored backup that cannot be decrypted).
      await _discard();
      return _Data();
    }
    if (raw == null || raw.isEmpty) return _Data();
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return _Data();
      final data = _Data()..active = json['active'] as String?;
      final map = json['pairings'];
      if (map is Map<String, dynamic>) {
        for (final e in map.entries) {
          final p = _decode(e.key, e.value);
          if (p != null) data.pairings[e.key] = p;
        }
      }
      return data;
    } catch (_) {
      await _discard();
      return _Data(); // Unreadable record: behave as "not paired".
    }
  }

  Future<void> _discard() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (_) {}
  }

  Future<void> _write(_Data data) => _storage.write(
    key: storageKey,
    value: jsonEncode({
      'active': data.active,
      'pairings': {
        for (final p in data.pairings.values)
          p.hubId: {
            'token': p.token,
            'host': p.lastHost,
            'port': p.lastPort,
            'name': p.hubName,
            'label': p.label,
          },
      },
    }),
  );

  static SavedHubPairing? _decode(String hubId, Object? v) {
    if (v is! Map) return null;
    final token = v['token'];
    final port = v['port'];
    if (token is! String || token.isEmpty || port is! int) return null;
    return SavedHubPairing(
      hubId: hubId,
      token: token,
      lastHost: v['host'] as String? ?? '',
      lastPort: port,
      hubName: v['name'] as String? ?? 'TV Saver',
      label: v['label'] as String?,
    );
  }

  @override
  Future<SavedHubPairing?> getPairing(String hubId) =>
      _locked(() async => (await _read()).pairings[hubId]);

  @override
  Future<SavedHubPairing?> getLastPairing() => _locked(() async {
    final d = await _read();
    return d.active == null ? null : d.pairings[d.active];
  });

  @override
  Future<void> savePairing(SavedHubPairing pairing) => _locked(() async {
    final d = await _read();
    final old = d.pairings[pairing.hubId];
    d.pairings[pairing.hubId] = pairing.label == null && old?.label != null
        ? pairing.copyWith(label: old!.label)
        : pairing;
    d.active = pairing.hubId;
    await _write(d);
  });

  @override
  Future<void> removePairing(String hubId) => _locked(() async {
    final d = await _read();
    if (d.pairings.remove(hubId) == null) return;
    if (d.active == hubId) {
      d.active = (d.pairings.keys.toList()..sort()).firstOrNull;
    }
    await _write(d);
  });

  @override
  Future<List<SavedHubPairing>> allPairings() => _locked(() async {
    final d = await _read();
    return [for (final k in d.pairings.keys.toList()..sort()) d.pairings[k]!];
  });

  @override
  Future<void> setActive(String hubId) => _locked(() async {
    final d = await _read();
    if (!d.pairings.containsKey(hubId)) return;
    d.active = hubId;
    await _write(d);
  });

  @override
  Future<void> setLabel(String hubId, String? label) => _locked(() async {
    final d = await _read();
    final p = d.pairings[hubId];
    if (p == null) return;
    final blank = label == null || label.trim().isEmpty;
    d.pairings[hubId] = blank
        ? p.copyWith(clearLabel: true)
        : p.copyWith(label: label.trim());
    await _write(d);
  });
}

class _Data {
  String? active;
  final Map<String, SavedHubPairing> pairings = {};
}
