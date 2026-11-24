import 'dart:typed_data';

import 'package:image/image.dart' as img;

bool isJpegBytes(Uint8List b) =>
    b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// True when [b] starts with the full 8-byte PNG signature.
bool isPngBytes(Uint8List b) {
  if (b.length < _pngSignature.length) return false;
  for (var i = 0; i < _pngSignature.length; i++) {
    if (b[i] != _pngSignature[i]) return false;
  }
  return true;
}

/// Pixel size declared by the header of a JPEG or PNG, read without decoding
/// any pixels. Null when [b] is not a readable JPEG or PNG header.
({int width, int height})? readImageHeaderSize(Uint8List b) {
  try {
    final decoder = isJpegBytes(b)
        ? img.JpegDecoder()
        : (isPngBytes(b) ? img.PngDecoder() : null);
    final info = decoder?.startDecode(b);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (width: info.width, height: info.height);
  } catch (_) {
    return null;
  }
}
