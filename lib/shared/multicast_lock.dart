import 'package:flutter/services.dart';

const _channel = MethodChannel('tvsaver/multicast');

/// Reference-counted Wi-Fi multicast lock (Android `WifiManager.MulticastLock`).
///
/// Many phones drop mDNS packets unless an app holds this lock. Hold it only
/// while scanning or reconnecting: every [acquire] needs one [release]. Errors
/// (no native side in tests or on other platforms) are ignored.
class MulticastLock {
  MulticastLock({MethodChannel channel = _channel}) : _ch = channel;

  final MethodChannel _ch;

  Future<void> acquire() => _call('acquire');
  Future<void> release() => _call('release');

  Future<void> _call(String method) async {
    try {
      await _ch.invokeMethod<void>(method);
    } catch (_) {
      // Not fatal (no native side, lock refused): discovery then relies on
      // the last known address.
    }
  }
}

/// Opens this app's system settings page (to re-enable a denied camera).
Future<void> openAppSettings({MethodChannel channel = _channel}) async {
  try {
    await channel.invokeMethod<void>('openSettings');
  } catch (_) {
    // Nothing more to do (no native side or settings unavailable).
  }
}
