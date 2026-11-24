import 'dart:convert';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

void main() {
  group('protocol', () {
    test('constants', () {
      expect(kHubService, '_tvsaver._tcp');
      expect(kDefaultHubPort, 8772);
      expect(kMaxFrameBytes, 64 * 1024);
    });

    test('decodeFrame ignores bad, oversized and type-less frames', () {
      expect(decodeFrame('{{{'), isNull);
      expect(decodeFrame('[]'), isNull);
      expect(decodeFrame(jsonEncode({'x': 1})), isNull);
      expect(decodeFrame(123), isNull);
      expect(
        decodeFrame(encodeFrame('a', {'p': 'x' * kMaxFrameBytes})),
        isNull,
      );
      expect(decodeFrame(encodeFrame('a', {'p': 1}))!['p'], 1);
    });

    test('QR uri round trip', () {
      const data = PairQrData(
        version: 1,
        host: '192.168.0.24',
        port: 8772,
        hubId: 'abc',
        pairCode: 'code_-1',
      );
      final uri = data.toUriString();
      expect(uri, startsWith('tvsaver://pair?'));
      final parsed = PairQrData.tryParse(uri)!;
      expect(parsed.host, '192.168.0.24');
      expect(parsed.port, 8772);
      expect(parsed.hubId, 'abc');
      expect(parsed.pairCode, 'code_-1');
      expect(PairQrData.tryParse('familyhub://pair?v=1&h=a&p=1&id=x'), isNull);
      expect(PairQrData.tryParse('tvsaver://pair?v=1&h=a&p=0&id=x'), isNull);
    });
  });

  group('clock offset', () {
    test('rtt compensated, lowest rtt of the last 5 wins', () {
      final c = ClockOffsetEstimator();
      // Phone sent at 1000, got the pong at 1100 (rtt 100); TV said 5050.
      // offset = 5050 + 50 - 1100 = 4000.
      c.addSample(sentTs: 1000, receivedAt: 1100, tvNow: 5050);
      expect(c.offsetMs, 4000);
      // A slower round trip with a skewed estimate must not replace it.
      c.addSample(sentTs: 2000, receivedAt: 2400, tvNow: 6000);
      expect(c.offsetMs, 4000);
      // A faster round trip wins: rtt 20, offset = 6010 + 10 - 3020 = 3000.
      c.addSample(sentTs: 3000, receivedAt: 3020, tvNow: 6010);
      expect(c.offsetMs, 3000);
    });

    test('only the last 5 samples count', () {
      final c = ClockOffsetEstimator();
      c.addSample(sentTs: 0, receivedAt: 2, tvNow: 1001); // rtt 2, off 1000
      for (var i = 1; i <= 5; i++) {
        c.addSample(
          sentTs: i * 100,
          receivedAt: i * 100 + 50,
          tvNow: i * 100 + 2025,
        );
      } // rtt 50, offset 2000
      expect(c.offsetMs, 2000);
    });

    test('provisional offset is replaced by real samples', () {
      final c = ClockOffsetEstimator()..setProvisional(5000, 1000);
      expect(c.offsetMs, 4000);
      c.addSample(sentTs: 0, receivedAt: 10, tvNow: 905);
      expect(c.offsetMs, 900);
      c.setProvisional(9999, 0);
      expect(c.offsetMs, 900);
    });
  });

  group('database', () {
    late HubDatabase db;
    setUp(() => db = HubDatabase.inMemory());
    tearDown(() => db.close());

    test(
      'first device is owner; tokens stored hashed; delete cascades',
      () async {
        expect(await db.nextDeviceRole(), 'owner');
        await db.insertDevice(id: 'd1', name: 'A', role: 'owner', nowMs: 1);
        expect(await db.nextDeviceRole(), 'controller');
        await db.insertPairing(
          rawToken: 'secret-token',
          deviceId: 'd1',
          clientName: 'A',
          nowMs: 1,
        );
        final stored = await db.allPairings();
        expect(stored.single.tokenHash, hashToken('secret-token'));
        expect(stored.single.tokenHash, isNot('secret-token'));
        expect(await db.verifyRawToken('secret-token'), isNotNull);
        expect(await db.verifyRawToken('nope'), isNull);

        await db.deleteDevice('d1');
        expect(await db.allPairings(), isEmpty);
        expect(await db.verifyRawToken('secret-token'), isNull);
      },
    );

    test('constantTimeEquals', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
    });
  });
}
