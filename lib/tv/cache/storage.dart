import 'package:flutter/services.dart';

const _channel = MethodChannel('tvsaver/storage');

/// Free bytes on the volume [path] is on, or null when Android does not say.
Future<int?> freeBytesOf(String path) async {
  try {
    return await _channel.invokeMethod<int>('freeBytes', {'path': path});
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
