import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

class _NoScan extends HubScanner {
  @override
  Stream<HubEndpoint> scan() => const Stream.empty();
}

void main() {
  late TestHubRig rig;
  setUp(() async => rig = await TestHubRig.start());
  tearDown(() => rig.dispose());

  int tvNow() => rig.clock.now().millisecondsSinceEpoch;

  test('a timer.changed style note seeds the clock for a client with no '
      'samples', () async {
    final client = HubClient(
      tokenStore: MemoryHubTokenStore(),
      clientName: 'x',
      scanner: _NoScan(),
      now: () => rig.clock.now().subtract(const Duration(milliseconds: 250)),
    );
    addTearDown(client.dispose);
    expect(client.tvNowMs(), tvNow() - 250);
    client.noteTvNow(tvNow());
    expect(client.tvNowMs(), tvNow());
  });

  test('the best clock sample is the one with the lowest round trip', () {
    final e = ClockOffsetEstimator();
    // A slow round trip suggests +400; a quick one is closer to the truth.
    e.addSample(sentTs: 1000, receivedAt: 1800, tvNow: 1000 + 250 + 400);
    e.addSample(sentTs: 2000, receivedAt: 2010, tvNow: 2000 + 250 + 5);
    expect(e.offsetMs, 250);
  });
}
