import 'dart:async';
import 'dart:convert';

import '../config.dart';
import '../db/hub_database.dart';
import 'hub_module.dart';

/// Why a settings change was refused. [field] names the setting.
class SettingsRejected extends HubError {
  SettingsRejected(String field, String message)
    : super('invalid', message, {'field': field});
}

/// A numeric setting's accepted range.
class SettingLimit {
  const SettingLimit(this.min, this.max);
  final int min;
  final int max;

  Map<String, Object?> toJson() => {'min': min, 'max': max};
}

/// The persisted settings: typed values, validation and change events.
///
/// Keys: `imageSeconds`, `transition`, `kenBurns`, `playWithSound`,
/// `storageCapBytes`, `streamingCeilingMbps`, `tvCacheBytes`. A key that was
/// never stored starts from the environment ([ServerConfig]) or the default.
/// The three byte and bitrate settings are written onto the [ServerConfig] so
/// live consumers (library, media worker) see changes without a restart.
class SettingsStore {
  SettingsStore({required this.db, required this.config});

  final HubDatabase db;
  final ServerConfig config;

  static const transitions = ['crossfade', 'cut'];

  static const limits = <String, SettingLimit>{
    'imageSeconds': SettingLimit(3, 120),
    'storageCapBytes': SettingLimit(1000000000, 1000000000000),
    'streamingCeilingMbps': SettingLimit(5, 500),
    'tvCacheBytes': SettingLimit(500000000, 3000000000),
  };

  static const _labels = {
    'imageSeconds': 'Photo time',
    'storageCapBytes': 'Storage limit',
    'streamingCeilingMbps': 'Streaming limit',
    'tvCacheBytes': 'TV cache size',
  };

  final _changes = StreamController<Map<String, Object?>>.broadcast();
  Map<String, Object?> _values = {};

  /// Emits the full values after every accepted update.
  Stream<Map<String, Object?>> get changes => _changes.stream;

  Map<String, Object?> get values => Map.of(_values);

  int get imageSeconds => _values['imageSeconds']! as int;
  String get transition => _values['transition']! as String;

  Map<String, Object?> get snapshot => {
    'values': values,
    'limits': {for (final e in limits.entries) e.key: e.value.toJson()},
  };

  /// Reads the stored values; fills the gaps from the config and defaults.
  Future<void> load() async {
    final stored = await db.allSettings();
    final out = <String, Object?>{
      'imageSeconds': 10,
      'transition': 'crossfade',
      'kenBurns': false,
      'playWithSound': true,
      'storageCapBytes': config.storageCapBytes,
      'streamingCeilingMbps': config.streamCeilingMbps,
      'tvCacheBytes': config.tvCacheBytes,
    };
    for (final e in stored.entries) {
      if (!out.containsKey(e.key)) continue;
      try {
        final v = jsonDecode(e.value);
        // A damaged row falls back to the default.
        if (_typeOk(out[e.key]!, v) && (v is! int || v > 0)) out[e.key] = v;
      } catch (_) {}
    }
    _values = out;
    _apply();
  }

  bool _typeOk(Object def, Object? v) =>
      (def is int && v is int) ||
      (def is bool && v is bool) ||
      (def is String && v is String && transitions.contains(v));

  void _apply() {
    config.storageCapBytes = _values['storageCapBytes']! as int;
    config.streamCeilingMbps = _values['streamingCeilingMbps']! as int;
    config.tvCacheBytes = _values['tvCacheBytes']! as int;
  }

  /// Validates [patch] (partial), stores it and announces the new values.
  /// Nothing changes when any entry is refused.
  Future<Map<String, Object?>> update(Map<String, dynamic> patch) async {
    if (patch.isEmpty) {
      throw const HubError('invalid', 'Nothing to change');
    }
    final clean = <String, Object?>{};
    for (final e in patch.entries) {
      clean[e.key] = _validate(e.key, e.value);
    }
    await db.writeSettings({
      for (final e in clean.entries) e.key: jsonEncode(e.value),
    });
    _values = {..._values, ...clean};
    _apply();
    if (!_changes.isClosed) _changes.add(values);
    return values;
  }

  Object _validate(String key, Object? v) {
    switch (key) {
      case 'imageSeconds':
      case 'storageCapBytes':
      case 'streamingCeilingMbps':
      case 'tvCacheBytes':
        final lim = limits[key]!;
        if (v is! num || v != v.truncate()) {
          throw SettingsRejected(key, '${_labels[key]} must be a whole number');
        }
        final n = v.toInt();
        if (n < lim.min || n > lim.max) {
          throw SettingsRejected(
            key,
            '${_labels[key]} must be between ${lim.min} and ${lim.max}',
          );
        }
        return n;
      case 'transition':
        if (v is! String || !transitions.contains(v)) {
          throw SettingsRejected(key, 'Transition must be crossfade or cut');
        }
        return v;
      case 'kenBurns':
      case 'playWithSound':
        if (v is! bool) {
          throw SettingsRejected(key, '$key must be on or off');
        }
        return v;
      default:
        throw SettingsRejected(key, 'Unknown setting $key');
    }
  }

  Future<void> dispose() => _changes.close();
}
