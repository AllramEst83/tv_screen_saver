import 'dart:typed_data';

/// Copies the primary image of a JPEG without touching its pixel data and
/// drops everything that says who took the photo or where: GPS and all other
/// EXIF, XMP, IPTC and other APPn blocks (including the Multi-Picture index),
/// comments, and anything appended after the end-of-image marker (e.g. an
/// Ultra HDR gain map).
///
/// Kept: JFIF (APP0), the ICC colour profile (APP2 `ICC_PROFILE`), the Adobe
/// colour-transform marker (APP14), and the EXIF orientation, rewritten as a
/// minimal EXIF block that holds nothing else. These change how the pixels
/// are shown, not who took the photo.
///
/// Returns null when [b] is not a well-formed JPEG.
Uint8List? stripJpegMetadata(Uint8List b) {
  final n = b.length;
  if (n < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var i = 2;
  while (i < n) {
    if (b[i] != 0xFF) return null;
    while (i + 1 < n && b[i + 1] == 0xFF) {
      i++;
    }
    if (i + 1 >= n) return null;
    final marker = b[i + 1];
    i += 2;
    if (marker == 0xD9) {
      out.add(const [0xFF, 0xD9]);
      return out.takeBytes();
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      out.add([0xFF, marker]);
      continue;
    }
    if (i + 2 > n) return null;
    final length = (b[i] << 8) | b[i + 1];
    if (length < 2 || i + length > n) return null;
    final payloadStart = i + 2;
    final end = i + length;
    if (_keep(marker, b, payloadStart, end)) {
      out.add([0xFF, marker]);
      out.add(Uint8List.sublistView(b, i, end));
    }
    i = end;
    if (marker == 0xDA) {
      var j = i;
      while (j < n) {
        if (b[j] != 0xFF) {
          j++;
          continue;
        }
        if (j + 1 >= n) return null;
        final next = b[j + 1];
        if (next == 0x00 || (next >= 0xD0 && next <= 0xD7)) {
          j += 2;
        } else if (next == 0xFF) {
          j++;
        } else {
          break;
        }
      }
      out.add(Uint8List.sublistView(b, i, j));
      i = j;
    }
  }
  return null; // no end-of-image marker
}

/// [stripJpegMetadata] plus the orientation block, placed after SOI.
Uint8List? stripJpegKeepOrientation(Uint8List b) {
  final stripped = stripJpegMetadata(b);
  if (stripped == null) return null;
  final o = jpegOrientation(b);
  if (o == null || o == 1) return stripped;
  final block = _orientationSegment(o);
  // After JFIF when the file starts with it, as cameras write it.
  var at = 2;
  if (stripped.length > 6 && stripped[2] == 0xFF && stripped[3] == 0xE0) {
    at = 4 + ((stripped[4] << 8) | stripped[5]);
  }
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(stripped, 0, at))
    ..add(block)
    ..add(Uint8List.sublistView(stripped, at));
  return out.takeBytes();
}

/// EXIF orientation (1..8) of a JPEG, or null when it has none.
int? jpegOrientation(Uint8List b) {
  var i = 2;
  final n = b.length;
  while (i + 4 <= n && b[i] == 0xFF) {
    final marker = b[i + 1];
    if (marker == 0xDA || marker == 0xD9) return null;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    final length = (b[i + 2] << 8) | b[i + 3];
    if (length < 2 || i + 2 + length > n) return null;
    if (marker == 0xE1) {
      final o = _exifOrientation(b, i + 4, i + 2 + length);
      if (o != null) return o;
    }
    i += 2 + length;
  }
  return null;
}

int? _exifOrientation(Uint8List b, int start, int end) {
  if (end - start < 14) return null;
  const tag = [0x45, 0x78, 0x69, 0x66, 0, 0]; // "Exif\0\0"
  for (var k = 0; k < tag.length; k++) {
    if (b[start + k] != tag[k]) return null;
  }
  final t = start + 6;
  final little = b[t] == 0x49 && b[t + 1] == 0x49;
  if (!little && !(b[t] == 0x4D && b[t + 1] == 0x4D)) return null;
  int u16(int p) => little ? b[p] | (b[p + 1] << 8) : (b[p] << 8) | b[p + 1];
  int u32(int p) => little
      ? b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
      : (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
  if (t + 8 > end) return null;
  final ifd = t + u32(t + 4);
  if (ifd < t || ifd + 2 > end) return null;
  final count = u16(ifd);
  for (var e = 0; e < count; e++) {
    final p = ifd + 2 + e * 12;
    if (p + 12 > end) return null;
    if (u16(p) == 0x0112) {
      final v = u16(p + 8);
      return v >= 1 && v <= 8 ? v : null;
    }
  }
  return null;
}

Uint8List _orientationSegment(int o) {
  final body = <int>[
    0x45, 0x78, 0x69, 0x66, 0, 0, // Exif\0\0
    0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, // big-endian TIFF, IFD at 8
    0, 1, // one entry
    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, o, 0, 0, // Orientation SHORT
    0, 0, 0, 0, // no next IFD
  ];
  final len = body.length + 2;
  return Uint8List.fromList([0xFF, 0xE1, len >> 8, len & 0xFF, ...body]);
}

bool _keep(int marker, Uint8List b, int start, int end) {
  if (marker == 0xFE) return false; // comment
  if (marker < 0xE0 || marker > 0xEF) return true; // not an APPn segment
  if (marker == 0xE0) return true; // JFIF
  if (marker == 0xE2) return _startsWith(b, start, end, 'ICC_PROFILE\u0000');
  if (marker == 0xEE) return _startsWith(b, start, end, 'Adobe');
  return false;
}

bool _startsWith(Uint8List b, int start, int end, String tag) {
  if (end - start < tag.length) return false;
  for (var k = 0; k < tag.length; k++) {
    if (b[start + k] != tag.codeUnitAt(k)) return false;
  }
  return true;
}
