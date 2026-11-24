import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/main_tv.dart';
import 'package:tv_saver/tv/pi/pi_config.dart';
import 'package:tv_saver/tv/pi/pi_player.dart';
import 'package:tv_saver/tv/pi/pi_screen.dart';
import 'package:tv_saver/tv/pi/throughput_runner.dart';
import 'package:tv_saver/tv/video_spike/spike_native.dart';

class _FakePiNative implements PiVideoNative {
  _FakePiNative({this.dir = '/files', this.statsQueue, this.currentStats});

  final String? dir;
  final List<Media3Stats?>? statsQueue;

  final List<({List<String> urls, Map<String, String> headers})> opens = [];
  int nextCount = 0;
  int prevCount = 0;
  int releaseCount = 0;
  Media3Stats? currentStats;

  @override
  Future<String?> filesDir() async => dir;

  @override
  Future<DisplayModeInfo?> displayInfo() async => const DisplayModeInfo(
    modeId: 1,
    width: 3840,
    height: 2160,
    refreshRate: 60,
  );

  @override
  Future<void> media3OpenHttp(
    List<String> urls,
    Map<String, String> headers,
  ) async {
    opens.add((urls: urls, headers: headers));
  }

  @override
  Future<Media3Stats?> media3Stats() async {
    if (statsQueue != null && statsQueue!.isNotEmpty) {
      return statsQueue!.removeAt(0);
    }
    return currentStats;
  }

  @override
  Future<void> media3Next() async => nextCount++;

  @override
  Future<void> media3Prev() async => prevCount++;

  @override
  Future<void> media3Release() async => releaseCount++;
}

Future<T> _withRealHttp<T>(Future<T> Function() fn) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await fn();
  } finally {
    HttpOverrides.global = saved;
  }
}

/// Real socket I/O resumes app `await`s in the fake-async zone, which only
/// advances on `pump`. Alternate short real delays with pumps until [done].
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration step = const Duration(milliseconds: 20),
  int maxSteps = 250,
}) async {
  for (var i = 0; i < maxSteps && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump(step);
  }
}

void main() {
  const secretToken = 'super-secret-token-never-print';

  group('PiConfig', () {
    test('parses valid config and keeps token out of URLs and toString', () {
      final cfg = PiConfig.parse(
        jsonEncode({
          'host': '192.168.0.43',
          'port': 8772,
          'token': secretToken,
          'playlist': ['1-sdr-lines.mp4', '2-hdr10-lines.mp4'],
          'throughputFile': 'throughput-1g.bin',
        }),
      );

      expect(cfg.host, '192.168.0.43');
      expect(cfg.port, 8772);
      expect(cfg.healthUri.toString(), 'http://192.168.0.43:8772/health');
      expect(cfg.playlistUris.map((u) => u.toString()).toList(), [
        'http://192.168.0.43:8772/media/1-sdr-lines.mp4/full',
        'http://192.168.0.43:8772/media/2-hdr10-lines.mp4/full',
      ]);
      expect(
        cfg.throughputUri.toString(),
        'http://192.168.0.43:8772/media/throughput-1g.bin/full',
      );
      expect(cfg.authHeaders, {'Authorization': 'Bearer $secretToken'});
      expect(cfg.toString(), isNot(contains(secretToken)));
    });

    test('loadPiConfig reads from disk and rejects missing/bad files', () async {
      final dir = Directory.systemTemp.createTempSync('pi_cfg_test');
      addTearDown(() => dir.deleteSync(recursive: true));

      await expectLater(
        loadPiConfig(dir.path),
        throwsA(isA<PiConfigException>()),
      );

      File('${dir.path}/pi_config.json').writeAsStringSync('{not json');
      await expectLater(
        loadPiConfig(dir.path),
        throwsA(isA<PiConfigException>()),
      );

      File('${dir.path}/pi_config.json').writeAsStringSync(
        jsonEncode({
          'host': '192.168.0.43',
          'port': 8772,
          'token': secretToken,
          'playlist': <String>[],
          'throughputFile': 'throughput-1g.bin',
        }),
      );
      try {
        await loadPiConfig(dir.path);
        fail('expected PiConfigException');
      } on PiConfigException catch (e) {
        expect(e.message, isNot(contains(secretToken)));
      }
    });
  });

  group('ThroughputRunner (loopback HTTP)', () {
    test('streams payload in memory, verifies Bearer auth, logs ceiling', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        final payload = Uint8List(256 * 1024);
        final seenUrls = <Uri>[];
        final seenAuth = <String?>[];
        server.listen((req) async {
          seenUrls.add(req.uri);
          seenAuth.add(req.headers.value(HttpHeaders.authorizationHeader));
          req.response.statusCode = 200;
          req.response.contentLength = payload.length * 4;
          for (var i = 0; i < 4; i++) {
            req.response.add(payload);
          }
          await req.response.close();
        });

        final cfg = PiConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: secretToken,
          playlist: const ['1.mp4'],
          throughputFile: 'throughput-1g.bin',
        );

        final runner = ThroughputRunner();
        final result = await runner.run(cfg);

        expect(seenUrls.single.toString(), '/media/throughput-1g.bin/full');
        expect(seenAuth.single, 'Bearer $secretToken');
        expect(result.bytes, payload.length * 4);
        expect(result.ceilingMbps, closeTo(result.mbps * 0.60, 1e-6));
        final line = piThroughputLogLine(result);
        expect(line, startsWith('PiThroughput: bytes=${payload.length * 4} '));
        expect(line, contains('mbps='));
        expect(line, contains('ceiling_mbps='));
        expect(line, isNot(contains(secretToken)));
      });
    });

    test('401 throws ThroughputException without bogus ceiling', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          req.response.statusCode = 401;
          req.response.contentLength = 0;
          await req.response.close();
        });

        final cfg = PiConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: 'wrong',
          playlist: const ['1.mp4'],
          throughputFile: 'throughput-1g.bin',
        );

        await expectLater(
          ThroughputRunner().run(cfg),
          throwsA(
            isA<ThroughputException>().having((e) => e.statusCode, 'status', 401),
          ),
        );
      });
    });

    test('short body (bytes < Content-Length) fails explicitly', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n');
          socket.add(Uint8List(1024));
          await socket.flush();
          socket.destroy();
        });

        final cfg = PiConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: secretToken,
          playlist: const ['1.mp4'],
          throughputFile: 'throughput-1g.bin',
        );

        await expectLater(
          ThroughputRunner().run(cfg),
          throwsA(isA<ThroughputException>()),
        );
      });
    });

    test('cancel closes client with force:true cleanly', () async {
      await _withRealHttp(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final closeServerGate = Completer<void>();
        addTearDown(() {
          if (!closeServerGate.isCompleted) closeServerGate.complete();
          return server.close(force: true);
        });

        final firstChunkSent = Completer<void>();
        server.listen((req) async {
          req.response.statusCode = 200;
          req.response.contentLength = 100 * 1024 * 1024;
          req.response.add(Uint8List(16384));
          await req.response.flush();
          if (!firstChunkSent.isCompleted) firstChunkSent.complete();
          await closeServerGate.future;
          try {
            await req.response.close();
          } catch (_) {}
        });

        final cfg = PiConfig(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: secretToken,
          playlist: const ['1.mp4'],
          throughputFile: 'throughput-1g.bin',
        );

        final runner = ThroughputRunner();
        final future = runner.run(cfg);
        final expectation = expectLater(
          future,
          throwsA(isA<ThroughputCancelledException>()),
        );
        await firstChunkSent.future;
        runner.cancel();

        await expectation;
      });
    });
  });

  group('PiScreen & PiPlayer widget tests', () {
    testWidgets('launcher OK opens Pi stream screen', (tester) async {
      await tester.pumpWidget(const TvSaverApp(version: '1'));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('Pi stream & throughput'), findsOneWidget);
    });

    testWidgets('missing/bad config shows error + setup_phase2.sh hint', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('pi_screen_missing');
      addTearDown(() => dir.deleteSync(recursive: true));
      final native = _FakePiNative(dir: dir.path);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PiScreen(native: native)),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      expect(find.textContaining('pi_config.json not found'), findsOneWidget);
      expect(find.text(setupPhase2Hint), findsOneWidget);
      expect(find.textContaining(secretToken), findsNothing);
    });

    testWidgets('valid config streams with Bearer, handles Left/Right/OK/Back', (
      tester,
    ) async {
      final native = _FakePiNative(
        currentStats: const Media3Stats(
          decoder: 'OMX.MTK.VIDEO.DECODER.HEVC',
          hdr: 'HDR10',
          droppedFrames: 0,
          position: Duration(seconds: 4),
          duration: Duration(seconds: 10),
          item: 1,
        ),
      );
      final cfg = const PiConfig(
        host: '192.168.0.43',
        port: 8772,
        token: secretToken,
        playlist: ['1-sdr.mp4', '2-hdr10.mp4'],
        throughputFile: 'throughput-1g.bin',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PiScreen(
              native: native,
              configLoader: (_) async => cfg,
              media3View: (onCreated) {
                Future.microtask(() => onCreated(0));
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Never render the bearer token on screen.
      expect(find.textContaining(secretToken), findsNothing);

      // OK on row 0 starts streaming.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();

      expect(find.byType(PiPlayer), findsOneWidget);
      expect(native.opens, hasLength(1));
      expect(native.opens.single.urls, [
        'http://192.168.0.43:8772/media/1-sdr.mp4/full',
        'http://192.168.0.43:8772/media/2-hdr10.mp4/full',
      ]);
      expect(native.opens.single.headers, {
        'Authorization': 'Bearer $secretToken',
      });

      // Wait for 1s stats tick to populate overlay.
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('2-hdr10.mp4'), findsOneWidget);
      expect(
        find.textContaining('OMX.MTK.VIDEO.DECODER.HEVC'),
        findsOneWidget,
      );
      expect(find.textContaining('HDR10'), findsOneWidget);
      expect(find.textContaining('dropped 0'), findsOneWidget);
      expect(find.textContaining('0:04 / 0:10'), findsOneWidget);

      // Left / Right control prev / next.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(native.nextCount, 1);
      expect(native.prevCount, 1);

      // OK hides and shows overlay.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(find.textContaining('OMX.MTK.VIDEO.DECODER.HEVC'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(
        find.textContaining('OMX.MTK.VIDEO.DECODER.HEVC'),
        findsOneWidget,
      );

      // Back stops playback and returns to menu.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byType(PiPlayer), findsNothing);
      expect(native.releaseCount, greaterThanOrEqualTo(1));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('401 shows auth failed (401) and halts retry', (tester) async {
      final logs = <String>[];
      var healthCalls = 0;
      final native = _FakePiNative(
        statsQueue: [
          const Media3Stats(
            httpStatus: 401,
            error: 'ERROR_CODE_IO_BAD_HTTP_STATUS: 401',
          ),
        ],
      );
      final cfg = const PiConfig(
        host: '192.168.0.43',
        port: 8772,
        token: secretToken,
        playlist: ['1-sdr.mp4'],
        throughputFile: 'throughput-1g.bin',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: PiPlayer(
            config: cfg,
            native: native,
            log: logs.add,
            onExit: () {},
            healthCheck: (_) async {
              healthCalls++;
              return true;
            },
            media3View: (onCreated) {
              Future.microtask(() => onCreated(0));
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 6));

      expect(find.text('auth failed (401)'), findsOneWidget);
      expect(find.text(setupPhase2Hint), findsOneWidget);
      expect(healthCalls, 0);
      expect(native.opens, hasLength(1));
      expect(logs, ['PiStream: auth failed (401)']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'Pi outage shows Reconnecting…, polls loopback /health, auto-resumes',
      (tester) async {
        await _withRealHttp(() async {
          final server = (await tester.runAsync(
            () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
          ))!;
          addTearDown(() => server.close(force: true));

          var healthy = false;
          var healthHits = 0;
          server.listen((req) async {
            if (req.uri.path == '/health') {
              healthHits++;
              req.response.statusCode = healthy ? 200 : 503;
              req.response.write(healthy ? '{"ok":true}' : '{}');
              await req.response.close();
              return;
            }
            req.response.statusCode = 404;
            await req.response.close();
          });

          final logs = <String>[];
          final native = _FakePiNative(
            statsQueue: [
              const Media3Stats(
                error: 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED: refused',
              ),
              const Media3Stats(decoder: 'c2.hevc', hdr: 'SDR'),
            ],
          );
          final cfg = PiConfig(
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            token: secretToken,
            playlist: const ['1-sdr.mp4'],
            throughputFile: 'throughput-1g.bin',
          );

          await tester.pumpWidget(
            MaterialApp(
              home: PiPlayer(
                config: cfg,
                native: native,
                log: logs.add,
                onExit: () {},
                healthCheck: (u) => Zone.root.run(() => defaultHealthCheck(u)),
                statsInterval: const Duration(milliseconds: 200),
                reconnectInterval: const Duration(milliseconds: 200),
                media3View: (onCreated) {
                  Future.microtask(() => onCreated(0));
                  return const SizedBox();
                },
              ),
            ),
          );
          await tester.pump();
          await tester.pump();
          expect(native.opens, hasLength(1));

          // First stats tick returns error -> Reconnecting…
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.text('Reconnecting…'), findsOneWidget);
          expect(
            logs.any((l) => l.startsWith('PiStream: disconnected')),
            isTrue,
          );

          // Probe while unhealthy: still reconnecting.
          await _pumpUntil(tester, () => healthHits >= 1);
          expect(healthHits, greaterThanOrEqualTo(1));
          expect(find.text('Reconnecting…'), findsOneWidget);
          expect(native.opens, hasLength(1));

          // Pi recovers -> /health 200 -> logs reconnected & reopens stream.
          healthy = true;
          await _pumpUntil(tester, () => native.opens.length >= 2);
          await tester.pump();
          expect(find.text('Reconnecting…'), findsNothing);
          expect(logs, contains('PiStream: reconnected'));
          expect(native.opens, hasLength(2));

          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'PiScreen throughput row runs loopback test, logs & shows ceiling; Back cancels',
      (tester) async {
        await _withRealHttp(() async {
          final server = (await tester.runAsync(
            () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
          ))!;
          final closeGate = Completer<void>();
          addTearDown(() {
            if (!closeGate.isCompleted) closeGate.complete();
            return server.close(force: true);
          });

          var slowMode = false;
          var fastDone = Completer<void>();
          var slowStarted = Completer<void>();
          server.listen((req) async {
            req.response.statusCode = 200;
            if (slowMode) {
              req.response.contentLength = 100 * 1024 * 1024;
              req.response.add(Uint8List(8192));
              await req.response.flush();
              if (!slowStarted.isCompleted) slowStarted.complete();
              await closeGate.future;
              try {
                await req.response.close();
              } catch (_) {}
              return;
            }
            final body = Uint8List(512 * 1024);
            req.response.contentLength = body.length;
            req.response.add(body);
            await req.response.close();
            if (!fastDone.isCompleted) fastDone.complete();
          });

          final logs = <String>[];
          final cfg = PiConfig(
            host: InternetAddress.loopbackIPv4.address,
            port: server.port,
            token: secretToken,
            playlist: const ['1-sdr.mp4'],
            throughputFile: 'throughput-1g.bin',
          );

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PiScreen(
                  native: _FakePiNative(),
                  configLoader: (_) async => cfg,
                  throughputRunner: ThroughputRunner(
                    clientFactory: () => Zone.root.run(HttpClient.new),
                  ),
                  log: logs.add,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Move to row 1 (throughput test) and start it.
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await _pumpUntil(tester, () => logs.isNotEmpty);
          await tester.pump();

          expect(find.textContaining('60% ceiling:'), findsOneWidget);
          expect(logs.single, startsWith('PiThroughput: bytes=524288 '));

          // Now run in slow mode and cancel with Back.
          slowMode = true;
          logs.clear();
          await tester.sendKeyEvent(LogicalKeyboardKey.select);
          await _pumpUntil(tester, () => slowStarted.isCompleted);
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await _pumpUntil(tester, () => false, maxSteps: 5);

          expect(find.text('Throughput test cancelled'), findsOneWidget);
          expect(find.textContaining('60% ceiling:'), findsNothing);
          expect(logs, isEmpty);

          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  });
}
