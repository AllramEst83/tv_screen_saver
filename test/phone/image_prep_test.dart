import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tv_saver/phone/images/image_prep.dart';
import 'package:tv_saver/phone/images/jpeg_strip.dart';

Uint8List _segment(int marker, List<int> body) {
  final len = body.length + 2;
  return Uint8List.fromList([0xFF, marker, len >> 8, len & 0xFF, ...body]);
}

/// Big-endian EXIF with Orientation and a GPS-looking string.
Uint8List _exif(int orientation) => _segment(0xE1, [
  ...'Exif\u0000\u0000'.codeUnits,
  0x4D,
  0x4D,
  0,
  0x2A,
  0,
  0,
  0,
  8,
  0,
  1,
  0x01,
  0x12,
  0,
  3,
  0,
  0,
  0,
  1,
  0,
  orientation,
  0,
  0,
  0,
  0,
  0,
  0,
  ...'GPS-LAT-52.1234'.codeUnits,
]);

img.Image _gradient(int w, int h) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p
      ..r = p.x * 255 ~/ w
      ..g = p.y * 255 ~/ h
      ..b = (p.x + p.y) % 256;
  }
  return image;
}

/// A JPEG with EXIF (orientation + "GPS"), XMP, a comment and trailing bytes.
Uint8List _photo({
  int w = 800,
  int h = 600,
  int orientation = 6,
  bool icc = true,
}) {
  final image = _gradient(w, h);
  if (icc) {
    image.iccProfile = img.IccProfile(
      'test',
      img.IccProfileCompression.none,
      Uint8List.fromList(List.generate(300, (i) => i % 256)),
    );
  }
  final base = img.encodeJpg(image, quality: 90);
  return Uint8List.fromList([
    ...base.sublist(0, 2),
    ..._exif(orientation),
    ..._segment(0xE1, [
      ...'http://ns.adobe.com/xap/1.0/\u0000XMP-SECRET'.codeUnits,
    ]),
    ..._segment(0xFE, 'comment-secret'.codeUnits),
    ...base.sublist(2),
    ...'GAINMAP-SECRET'.codeUnits,
  ]);
}

bool _contains(Uint8List b, String needle) =>
    latin1.decode(b, allowInvalid: true).contains(needle);

void main() {
  group('JPEG that already fits', () {
    test('keeps pixels, ICC and orientation; drops everything else', () {
      final src = _photo();
      final out = prepareImageSync(src)!;
      expect(out.mime, 'image/jpeg');
      // Orientation 6 turns the 800x600 sensor image upright: 600x800.
      expect(out.width, 600);
      expect(out.height, 800);
      for (final secret in [
        'GPS-LAT',
        'XMP-SECRET',
        'comment-secret',
        'GAINMAP-SECRET',
      ]) {
        expect(_contains(src, secret), isTrue);
        expect(_contains(out.bytes, secret), isFalse, reason: secret);
      }
      expect(jpegOrientation(out.bytes), 6);
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.iccProfile, isNotNull);
      // The pixels are the very same: no second compression.
      final before = img.decodeJpg(src)!;
      expect(decoded.getBytes(), before.getBytes());
      expect(out.sha256, hasLength(64));
    });

    test('upright photo gets no EXIF at all', () {
      final out = prepareImageSync(_photo(orientation: 1, icc: false))!;
      expect(jpegOrientation(out.bytes), isNull);
      expect(_contains(out.bytes, 'Exif'), isFalse);
      expect(img.decodeJpg(out.bytes), isNotNull);
    });
  });

  group('bigger than 4096 px', () {
    test('is scaled once, keeps its ICC profile, loses its metadata', () {
      final out = prepareImageSync(_photo(w: 5000, h: 1000))!;
      // Orientation 6 is applied to the pixels: the long edge is now tall.
      expect(out.width, 819);
      expect(out.height, 4096);
      expect(_contains(out.bytes, 'GPS-LAT'), isFalse);
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.height, 4096);
      expect(decoded.iccProfile, isNotNull);
    });
  });

  group('PNG', () {
    test('stays PNG with its transparency', () {
      final image = img.Image(width: 20, height: 10, numChannels: 4)
        ..clear(img.ColorRgba8(10, 20, 30, 128));
      final out = prepareImageSync(Uint8List.fromList(img.encodePng(image)))!;
      expect(out.mime, 'image/png');
      expect(img.decodePng(out.bytes)!.hasAlpha, isTrue);
    });
  });

  test('a file that is not a picture is refused', () async {
    await expectLater(
      prepareImage(Uint8List.fromList('hello'.codeUnits)),
      throwsA(isA<ImagePrepException>()),
    );
  });
}
