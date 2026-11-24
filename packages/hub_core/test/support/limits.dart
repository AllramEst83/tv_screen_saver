import 'package:hub_core/hub_core.dart';

/// Wide-open limits so tests can use tiny caps and cache sizes.
const openLimits = <String, SettingLimit>{
  'imageSeconds': SettingLimit(3, 120),
  'storageCapBytes': SettingLimit(1, 1 << 50),
  'streamingCeilingMbps': SettingLimit(1, 100000),
  'tvCacheBytes': SettingLimit(1, 1 << 50),
};
