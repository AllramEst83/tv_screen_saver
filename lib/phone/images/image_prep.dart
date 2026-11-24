import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import 'image_header.dart';
import 'jpeg_strip.dart';

/// Long edge limit of stored images. Above a 4K panel's 3840 px so a
/// full-screen image is never enlarged and zoom has headroom.
const kMaxLongEdge = 4096;

/// Photos with more pixels than this are refused before decoding.
const kMaxSourcePixels = 64 * 1000 * 1000;

/// The Pi accepts images up to 80 MB.
const kMaxImageBytes = 80 * 1000 * 1000;

/// JPEG quality used when an image has to be encoded (once, never twice).
const kJpegQuality = 95;

/// The picked file cannot be used.
class ImagePrepException implements Exception {
  const ImagePrepException([this.message = "That file isn't a picture"]);

  final String message;

  @override
  String toString() => message;
}

/// An image ready for upload.
class PreparedImage {
  const PreparedImage({
    required this.bytes,
    required this.mime,
    required this.width,
    required this.height,
    required this.sha256,
  });

  final Uint8List bytes;

  /// `image/jpeg` or `image/png`.
  final String mime;
  final int width;
  final int height;

  /// Lowercase hex SHA-256 of [bytes].
  final String sha256;
}

/// Prepares [source] in a background isolate.
Future<PreparedImage> prepareImage(Uint8List source) async {
  try {
    final result = await Isolate.run(() => prepareImageSync(source));
    if (result == null) throw const ImagePrepException();
    return result;
  } on ImagePrepException {
    rethrow;
  } on Object catch (e) {
    // An exception thrown inside the isolate arrives as the same type.
    if (e is ImagePrepException) rethrow;
    throw const ImagePrepException();
  }
}

/// Synchronous worker behind [prepareImage]; null when undecodable.
PreparedImage? prepareImageSync(Uint8List source) {
  final size = readImageHeaderSize(source);
  if (size != null && size.width * size.height > kMaxSourcePixels) {
    throw const ImagePrepException('This photo is too large to process');
  }
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;

  // A JPEG that already fits keeps its pixel data byte for byte: only the
  // metadata segments go, ICC and orientation stay.
  if (isJpegBytes(source) &&
      max(decoded.width, decoded.height) <= kMaxLongEdge) {
    final stripped = stripJpegKeepOrientation(source);
    if (stripped != null && stripped.length <= kMaxImageBytes) {
      return _prepared(stripped, 'image/jpeg', decoded.width, decoded.height);
    }
  }

  var image = decoded;
  final icc = image.iccProfile;
  if (image.hasPalette || image.format != img.Format.uint8) {
    image = image.convert(
      format: img.Format.uint8,
      numChannels: image.hasAlpha ? 4 : 3,
    );
  }
  image = img.bakeOrientation(image);

  if (max(image.width, image.height) > kMaxLongEdge) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: kMaxLongEdge,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: kMaxLongEdge,
            interpolation: img.Interpolation.average,
          );
  }

  // Metadata off, colour profile on.
  image
    ..exif = img.ExifData()
    ..iccProfile = icc
    ..textData = null;

  final png = isPngBytes(source);
  Uint8List out;
  String mime;
  if (png) {
    out = img.encodePng(image);
    mime = 'image/png';
  } else {
    if (image.hasAlpha) {
      final flat = img.Image(width: image.width, height: image.height)
        ..clear(img.ColorRgb8(255, 255, 255));
      img.compositeImage(flat, image);
      flat.iccProfile = icc;
      image = flat;
    }
    out = img.encodeJpg(image, quality: kJpegQuality);
    mime = 'image/jpeg';
  }
  if (out.length > kMaxImageBytes) {
    throw const ImagePrepException('This picture is too big for the Pi');
  }
  return _prepared(out, mime, image.width, image.height);
}

PreparedImage _prepared(Uint8List bytes, String mime, int w, int h) =>
    PreparedImage(
      bytes: bytes,
      mime: mime,
      width: w,
      height: h,
      sha256: sha256.convert(bytes).toString(),
    );
