import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the TV from dimming or sleeping while something plays.
abstract interface class AwakeGuard {
  Future<void> hold();
  Future<void> release();
}

/// [AwakeGuard] on the platform wake lock. A failure is logged and never
/// stops the picture.
class WakelockAwakeGuard implements AwakeGuard {
  const WakelockAwakeGuard();

  @override
  Future<void> hold() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('TV Saver: wake lock not held: $e');
    }
  }

  @override
  Future<void> release() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('TV Saver: wake lock not released: $e');
    }
  }
}
