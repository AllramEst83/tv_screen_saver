import 'dart:async';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

Future<void> until(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met in $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

bool isChanged(Map<String, dynamic> m) =>
    m['t'] == HubMsg.event && m['kind'] == 'player.changed';

List<Map<String, dynamic>> framesOf(TestPhone p, String type) => [
  for (final m in p.receivedHistory)
    if (m['t'] == type) m,
];

void main() {
  late TestHubRig rig;
  late TestPhone tv;
  late TestPhone phone;
  final blocked = <String, String>{};
  var capsChanges = 0;

  setUp(() async {
    blocked.clear();
    capsChanges = 0;
    rig = await TestHubRig.start(
      playlists: StaticPlaylistSource({
        'all': ['a.mp4', 'b.mp4', 'c.mp4'],
      }),
      unplayableReason: (id) async => blocked[id],
      onCapabilitiesChanged: () async => capsChanges++,
    );
    tv = await rig.onboardDisplay();
    phone = await rig.onboardPhone('Owner');
  });
  tearDown(() => rig.dispose());

  List<String> loads() => [
    for (final m in framesOf(tv, 'display.load')) m['itemId'] as String,
  ];

  test(
    'display.capabilities: first report and a change fire, a repeat not',
    () async {
      final caps = {
        'decoders': ['hevc'],
        'hdr': ['HDR10'],
        'render': '3840x2160',
        'panel': '3840x2160',
      };
      var r = await tv.request('display.capabilities', caps);
      expect(r['t'], HubMsg.ok);
      expect(capsChanges, 1);
      r = await tv.request('display.capabilities', {
        ...caps,
        'hdr': ['HLG'],
      });
      expect(r['t'], HubMsg.ok);
      expect(capsChanges, 2);
      r = await tv.request('display.capabilities', {
        ...caps,
        'hdr': ['HLG'],
      });
      expect(r['t'], HubMsg.ok);
      expect(capsChanges, 2);
    },
  );

  test(
    'player.play on an unplayable item gives err invalid, no load',
    () async {
      blocked['a.mp4'] =
          'HDR10 is not supported by this TV; convert it on the PC';
      final r = await phone.request('player.play', {'playlistId': 'all'});
      expect(r['t'], HubMsg.err);
      expect(r['code'], HubErrorCode.invalid);
      expect(
        r['message'] ?? r['msg'] ?? '$r',
        contains('convert it on the PC'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(loads(), isEmpty);
      expect(framesOf(phone, HubMsg.event).where((m) => isChanged(m)), isEmpty);
    },
  );

  test('next, prev and ended skip unplayable items', () async {
    expect(
      (await phone.request('player.play', {'playlistId': 'all'}))['t'],
      HubMsg.ok,
    );
    await until(() => loads().length == 1);
    blocked['b.mp4'] = 'no';
    await phone.request('player.next', {});
    await until(() => loads().length == 2);
    expect(loads().last, 'c.mp4');
    blocked['b.mp4'] = 'no';
    await phone.request('player.prev', {});
    await until(() => loads().length == 3);
    expect(loads().last, 'a.mp4');
    // The TV reports the end of a.mp4: b is skipped again.
    final r = await tv.request('player.ended', {'itemId': 'a.mp4'});
    expect(r['t'], HubMsg.ok);
    await until(() => loads().length == 4);
    expect(loads().last, 'c.mp4');
  });

  test('nothing playable: idle and display.control stop', () async {
    await phone.request('player.play', {'playlistId': 'all'});
    await until(() => loads().length == 1);
    blocked
      ..['a.mp4'] = 'no'
      ..['b.mp4'] = 'no'
      ..['c.mp4'] = 'no';
    await phone.request('player.next', {});
    await until(
      () => framesOf(tv, 'display.control').any((m) => m['action'] == 'stop'),
    );
    expect(loads().length, 1);
    final changed = framesOf(phone, HubMsg.event).where(isChanged).last;
    expect((changed['data'] as Map)['state'], 'idle');
  });

  test(
    'a reconnect report for an item that became unplayable moves on',
    () async {
      await phone.request('player.play', {'playlistId': 'all'});
      await until(() => loads().length == 1);
      // A phone command arrived since the TV connected: the report is stale
      // and the Pi puts the TV right. The item is unplayable by now.
      blocked['a.mp4'] = 'no';
      final r = await tv.request('player.report', {
        'playlistId': 'all',
        'index': 0,
        'itemId': 'a.mp4',
        'state': 'playing',
        'positionMs': 0,
      });
      expect(r['t'], HubMsg.ok);
      await until(() => loads().length == 2);
      expect(loads().last, 'b.mp4');
    },
  );
}
