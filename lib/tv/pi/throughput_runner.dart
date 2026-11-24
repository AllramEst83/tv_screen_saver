import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'pi_config.dart';

/// Live progress snapshot emitted while streaming the throughput benchmark.
class ThroughputProgress {
  const ThroughputProgress({
    required this.bytes,
    required this.expectedBytes,
    required this.seconds,
  });

  final int bytes;

  /// Expected total bytes from `Content-Length`, or `-1` when unknown.
  final int expectedBytes;
  final double seconds;

  double get mbPerSec => seconds > 0 ? (bytes / 1e6) / seconds : 0;
  double get mbps => seconds > 0 ? (bytes * 8) / (seconds * 1e6) : 0;
  double? get fraction =>
      expectedBytes > 0 ? (bytes / expectedBytes).clamp(0.0, 1.0) : null;
}

/// Final measurement from a completed throughput benchmark.
class ThroughputResult {
  const ThroughputResult({
    required this.bytes,
    required this.seconds,
    required this.mbps,
    required this.ceilingMbps,
  });

  final int bytes;
  final double seconds;
  final double mbps;
  final double ceilingMbps;

  double get mbPerSec => mbps / 8;
}

/// Formats the `PiThroughput:` logcat line required by story 2-3.
String piThroughputLogLine(ThroughputResult r) =>
    'PiThroughput: bytes=${r.bytes} seconds=${r.seconds.toStringAsFixed(2)} '
    'mbps=${r.mbps.toStringAsFixed(2)} '
    'ceiling_mbps=${r.ceilingMbps.toStringAsFixed(2)}';

/// Failure during the HTTP throughput test (e.g. 401, drop, or short body).
class ThroughputException implements Exception {
  const ThroughputException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ThroughputException: $message';
}

/// Thrown when the caller cancels an active throughput test.
class ThroughputCancelledException implements Exception {
  const ThroughputCancelledException();

  @override
  String toString() => 'ThroughputCancelledException: cancelled';
}

/// Streams `GET /media/<throughputFile>/full` in memory (zero flash writes)
/// and calculates sustained Mbps plus the 60 % streaming ceiling.
class ThroughputRunner {
  ThroughputRunner({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  HttpClient? _activeClient;
  bool _cancelled = false;

  /// Cancels an active run immediately by closing the underlying `HttpClient`
  /// with `force: true`.
  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
    _activeClient = null;
  }

  /// Runs the benchmark against [config]. Emits periodic [onProgress] updates
  /// (at least every ~200 ms and on completion). Throws
  /// [ThroughputCancelledException] if [cancel] is called, or
  /// [ThroughputException] on HTTP errors, drops, or short bodies.
  Future<ThroughputResult> run(
    PiConfig config, {
    void Function(ThroughputProgress progress)? onProgress,
    Duration progressInterval = const Duration(milliseconds: 200),
  }) async {
    _cancelled = false;
    final client = _clientFactory();
    client.connectionTimeout = const Duration(seconds: 10);
    _activeClient = client;

    var forceClose = false;
    try {
      final req = await client.getUrl(config.throughputUri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.token}');
      final res = await req.close();

      if (_cancelled) throw const ThroughputCancelledException();
      if (res.statusCode == HttpStatus.unauthorized) {
        forceClose = true;
        throw const ThroughputException('auth failed (401)', statusCode: 401);
      }
      if (res.statusCode != HttpStatus.ok) {
        forceClose = true;
        throw ThroughputException(
          'HTTP ${res.statusCode}',
          statusCode: res.statusCode,
        );
      }

      final expectedBytes = res.contentLength;
      final sw = Stopwatch()..start();
      var bytes = 0;
      var lastEmitUs = 0;
      final intervalUs = progressInterval.inMicroseconds;

      await for (final chunk in res) {
        if (_cancelled) throw const ThroughputCancelledException();
        bytes += chunk.length;
        final nowUs = sw.elapsedMicroseconds;
        if (onProgress != null && nowUs - lastEmitUs >= intervalUs) {
          lastEmitUs = nowUs;
          onProgress(
            ThroughputProgress(
              bytes: bytes,
              expectedBytes: expectedBytes,
              seconds: math.max(nowUs / 1e6, 1e-6),
            ),
          );
        }
      }

      sw.stop();
      if (_cancelled) throw const ThroughputCancelledException();

      if (expectedBytes >= 0 && bytes < expectedBytes) {
        forceClose = true;
        throw ThroughputException(
          'short body: received $bytes of $expectedBytes bytes',
        );
      }
      if (bytes == 0) {
        forceClose = true;
        throw const ThroughputException('empty body (0 bytes)');
      }

      final seconds = math.max(sw.elapsedMicroseconds / 1e6, 1e-6);
      onProgress?.call(
        ThroughputProgress(
          bytes: bytes,
          expectedBytes: expectedBytes,
          seconds: seconds,
        ),
      );

      final mbps = (bytes * 8) / (seconds * 1e6);
      return ThroughputResult(
        bytes: bytes,
        seconds: seconds,
        mbps: mbps,
        ceilingMbps: mbps * 0.60,
      );
    } on ThroughputCancelledException {
      forceClose = true;
      rethrow;
    } on ThroughputException {
      forceClose = true;
      rethrow;
    } catch (e) {
      forceClose = true;
      if (_cancelled) throw const ThroughputCancelledException();
      throw ThroughputException(e.toString());
    } finally {
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
      client.close(force: forceClose);
    }
  }
}
