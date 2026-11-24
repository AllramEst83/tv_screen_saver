import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

class _NoScanner extends HubScanner {
  @override
  Stream<HubEndpoint> scan() => const Stream.empty();
}

HubClient _client(HubTokenStore store) => HubClient(
  tokenStore: store,
  clientName: 'Phone',
  scanner: _NoScanner(),
  directTimeout: const Duration(milliseconds: 800),
  mdnsTimeout: const Duration(milliseconds: 100),
);

void main() {
  late TestHubRig rig;
  setUp(() async => rig = await TestHubRig.start());
  tearDown(() => rig.dispose());

  test('no pairing session: says to start pairing on the TV, not "TV not found"', () async {
    rig.server.openPairingSession();
    final qr = rig.server.currentQrUri('127.0.0.1')!;
    rig.server.closePairingSession();
    final client = _client(MemoryHubTokenStore());
    addTearDown(client.dispose);

    expect(await client.connectFromQrUri(qr), isFalse);
    final st = client.state.value;
    expect(st.phase, HubConnectionPhase.disconnected);
    expect(st.lastError, HubMessages.pairingNotOpen);
  });

  test('a token the hub no longer knows is dropped and reported as revoked', () async {
    final store = MemoryHubTokenStore();
    final client = _client(store);
    addTearDown(client.dispose);
    rig.server.openPairingSession();
    expect(
      await client.connectFromQrUri(rig.server.currentQrUri('127.0.0.1')!),
      isTrue,
    );
    while (await store.getLastPairing() == null) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await client.disconnect();
    rig.server.closePairingSession();
    await rig.server.forgetAllPhones();

    expect(await client.reconnectSavedHub(), isFalse);
    expect(client.state.value.lastError, HubMessages.revoked);
    expect(client.state.value.knownPairing, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await store.getLastPairing(), isNull);
  });
}
