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
    } on PlatformException {
      // Not fatal: discovery then relies on the last known address.
    } on MissingPluginException {
      // No native side (tests, non-Android).
    }
  }
}

/// Opens this app's system settings page (to re-enable a denied camera).
Future<void> openAppSettings({MethodChannel channel = _channel}) async {
  try {
    await channel.invokeMethod<void>('openSettings');
  } on PlatformException {
    // Nothing more to do.
  } on MissingPluginException {
    // No native side.
  }
}
