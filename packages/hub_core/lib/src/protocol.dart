import 'dart:convert';

/// Hub Protocol v1 constants and frame codecs shared between TV and phone.
const kProtocolVersion = 2;
const kHubService = '_drawaid._tcp';
const kDefaultHubPort = 8771;
const kWsPath = '/ws';
const kMaxFrameBytes = 64 * 1024;
const kQrScheme = 'drawaid';

/// Core handshake and transport message types.
abstract final class HubMsg {
  // Phone -> TV
  static const hello = 'hello';
  static const pair = 'pair';
  static const ping = 'ping';
  static const sync = 'sync';

  // TV -> Phone
  static const pairRequired = 'pair_required';
  static const paired = 'paired';
  static const pairFailed = 'pair_failed';
  static const ready = 'ready';
  static const snapshot = 'snapshot';
  static const event = 'event';
  static const ok = 'ok';
  static const err = 'err';
  static const pong = 'pong';
  static const replaced = 'replaced';
}

/// Standard protocol error codes.
abstract final class HubErrorCode {
  static const invalid = 'invalid';
  static const unauthorized = 'unauthorized';
  static const forbidden = 'forbidden';
  static const notFound = 'not_found';
  static const conflict = 'conflict';
  static const rateLimited = 'rate_limited';
  static const upgradeTv = 'upgrade_tv';
}

/// Encodes a protocol frame as a UTF-8 JSON string with `"t": type`.
String encodeFrame(String type, [Map<String, Object?> fields = const {}]) =>
    jsonEncode(<String, Object?>{'t': type, ...fields});

/// Decodes a protocol frame. Returns `null` if [raw] is not a String, exceeds
/// [kMaxFrameBytes] (UTF-8 bytes), is invalid JSON, lacks a string `"t"`, or
/// (when [knownTypes] is provided) has an unknown type.
Map<String, dynamic>? decodeFrame(Object? raw, {Set<String>? knownTypes}) {
  if (raw is! String) return null;
  if (utf8.encode(raw).length > kMaxFrameBytes) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final t = decoded['t'];
    if (t is! String || t.isEmpty) return null;
    if (knownTypes != null && !knownTypes.contains(t)) return null;
    return decoded;
  } catch (_) {
    return null;
  }
}

/// Parsed representation of the TV pairing QR code URI:
/// `drawaid://pair?v=1&h=192.168.0.24&p=8771&id=<hubId>&c=<pairCode>`
class PairQrData {
  const PairQrData({
    required this.version,
    required this.host,
    required this.port,
    required this.hubId,
    this.pairCode,
  });

  final int version;
  final String host;
  final int port;
  final String hubId;
  final String? pairCode;

  String toUriString() {
    final params = <String, String>{
      'v': '$version',
      'h': host,
      'p': '$port',
      'id': hubId,
      if (pairCode != null && pairCode!.isNotEmpty) 'c': pairCode!,
    };
    return Uri(
      scheme: kQrScheme,
      host: 'pair',
      queryParameters: params,
    ).toString();
  }

  static PairQrData? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != kQrScheme || uri.host != 'pair') {
      return null;
    }
    final v = int.tryParse(uri.queryParameters['v'] ?? '');
    final host = uri.queryParameters['h']?.trim();
    final port = int.tryParse(uri.queryParameters['p'] ?? '');
    final id = uri.queryParameters['id']?.trim();
    final code = uri.queryParameters['c']?.trim();
    if (v == null ||
        v < 1 ||
        host == null ||
        host.isEmpty ||
        port == null ||
        port <= 0 ||
        port > 65535) {
      return null;
    }
    if (id == null || id.isEmpty) return null;
    return PairQrData(
      version: v,
      host: host,
      port: port,
      hubId: id,
      pairCode: (code != null && code.isNotEmpty) ? code : null,
    );
  }
}
