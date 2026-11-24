import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/phone/phone_controller.dart';
import 'package:tv_saver/tv/video_spike/spike_native.dart';

import '../phone/support.dart';
import 'support.dart';

void main() {
  late Rig rig;
  late StaticPlaylistSource playlists;
  final tvs = <TvRig>[];
  final phones = <PhoneRig>[];
  Directory? tempDir;

  setUp(() async {
    playlists = StaticPlaylistSource({
      'all': ['a.mp4', 'b.mp4', 'c.mp4'],
    });
    rig = await Rig.start(playlists: playlists);
  });

  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
    for (final t in tvs) {
      t.dispose();
    }
    tvs.clear();
    await rig.dispose();
    tempDir?.deleteSync(recursive: true);
    tempDir = null;
  });

  TvRig newTv() {
    final t = TvRig(rig);
    tvs.add(t);
    return t;
  }

  /// A phone paired through the QR code the TV shows.
  Future<PhoneRig> pairPhone(TvRig tv) async {
    await until(() => tv.display.pairing != null);
    final p = PhoneRig();
    phones.add(p);
    await p.controller.start();
    await p.controller.pairFromQr(tv.display.pairing!.qr);
    await p.waitFor(PhoneScreen.home);
    await until(() => !tv.display.needsPairing);
    return p;
  }

  Future<String> tvToken(TvRig tv) async =>
      (await tv.store.getLastPairing())!.token;

  Future<Map<String, dynamic>> piPlayer() async {
    final snap = await rig.server.buildFullSnapshot(DeviceInfo.tv);
    return (snap['modules'] as Map)['player'] as Map<String, dynamic>;
  }

  group('connecting and pairing', () {
    test(
      'a fresh TV joins as the display and shows the pairing code',
      () async {
        final tv = newTv();
        await tv.start();
        expect(tv.client.state.value.device!.role, DeviceRole.display);
        expect((await tv.store.getLastPairing())!.token, isNotEmpty);

        // No phone is paired: the pairing session opens and the QR arrives.
        await until(() => tv.display.pairing != null);
        expect(tv.display.needsPairing, isTrue);
        final qr = PairQrData.tryParse(tv.display.pairing!.qr)!;
        expect(qr.port, rig.server.port);
        expect(tv.display.pairing!.pin, hasLength(kPinLength));

        // The capabilities went to the Pi on connect.
        final id = tv.client.state.value.device!.id;
        await until(() => rig.display!.capabilitiesFor(id) != null);
        expect(rig.display!.capabilitiesFor(id)!['hdr'], ['HDR10']);
        expect(rig.display!.capabilitiesFor(id)!['panel'], '3840x2160');
      },
    );

    test(
      'a phone that scans the QR pairs as owner and the TV moves on',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        expect(phone.controller.me!.role, DeviceRole.owner);
        expect(tv.display.pairing, isNull);
        // The Pi's session closed with the TV's cancel.
        await until(() => rig.server.pairingCredentials.value == null);
      },
    );

    test('hold Back: forgetAll returns the TV to the pairing screen', () async {
      final tv = newTv();
      await tv.start();
      final phone = await pairPhone(tv);

      await tv.display.forgetAllPhones();
      await until(() => tv.display.needsPairing);
      await until(() => tv.display.pairing != null);
      expect(await rig.db.phoneCount(), 0);
      await until(() => phone.controller.screen != PhoneScreen.home);
    });

    test('Menu can open a pairing code for another phone', () async {
      final tv = newTv();
      await tv.start();
      await pairPhone(tv);
      expect(tv.display.needsPairing, isFalse);

      tv.display.pairAnotherPhone();
      await until(() => tv.display.pairing != null);
      expect(tv.display.needsPairing, isTrue);

      // The second phone pairs; the screen closes by itself.
      final second = PhoneRig();
      phones.add(second);
      await second.controller.start();
      await second.controller.pairFromQr(tv.display.pairing!.qr);
      await second.waitFor(PhoneScreen.home);
      await until(() => !tv.display.needsPairing);
      expect(second.controller.me!.role, DeviceRole.controller);
    });

    test('back out of the pairing screen the user asked for', () async {
      final tv = newTv();
      await tv.start();
      await pairPhone(tv);
      tv.display.pairAnotherPhone();
      await until(() => tv.display.pairing != null);
      tv.display.stopPairing();
      expect(tv.display.needsPairing, isFalse);
      await until(() => rig.server.pairingCredentials.value == null);
    });
  });

  group('playing', () {
    test('Play on the phone streams item 0 with the display token', () async {
      final tv = newTv();
      await tv.start();
      final phone = await pairPhone(tv);

      await phone.controller.play();
      await until(() => tv.native.opens.isNotEmpty);
      final open = tv.native.opens.single;
      expect(open.url, 'http://127.0.0.1:${rig.server.port}/media/a.mp4/full');
      expect(open.headers, {'Authorization': 'Bearer ${await tvToken(tv)}'});
      expect(open.startMs, 0);
      expect(open.muted, isFalse);
      expect(open.playing, isTrue);

      await until(() => phone.controller.nowPlaying.itemId == 'a.mp4');
      expect(phone.controller.nowPlaying.isPlaying, isTrue);
      expect(tv.display.player.itemId, 'a.mp4');
    });

    test(
      'remote Right and phone Next both advance; both show the same',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);

        await tv.display.next(); // the remote
        await until(() => tv.native.opens.length == 2);
        expect(tv.native.opens.last.url, endsWith('/media/b.mp4/full'));
        await until(() => phone.controller.nowPlaying.itemId == 'b.mp4');
        expect(phone.controller.nowPlaying.index, 1);

        await phone.controller.next();
        await until(() => tv.native.opens.length == 3);
        expect(tv.native.opens.last.url, endsWith('/media/c.mp4/full'));
        await until(() => phone.controller.nowPlaying.itemId == 'c.mp4');
        expect(tv.display.player.itemId, 'c.mp4');

        await tv.display.prev();
        await until(() => tv.native.opens.length == 4);
        expect(tv.native.opens.last.url, endsWith('/media/b.mp4/full'));
      },
    );

    test('pause, resume, seek and mute from phone and remote', () async {
      final tv = newTv();
      await tv.start();
      final phone = await pairPhone(tv);
      await phone.controller.play();
      await until(() => tv.native.opens.length == 1);

      await phone.controller.togglePause();
      await until(() => tv.native.calls.contains('pause'));
      await until(() => phone.controller.nowPlaying.state == 'paused');
      expect(tv.display.player.playing, isFalse);

      await tv.display.togglePause(); // the remote's OK resumes
      await until(() => tv.native.calls.contains('resume'));
      await until(() => phone.controller.nowPlaying.isPlaying);

      await phone.controller.toggleMute();
      await until(() => tv.native.calls.contains('mute:true'));
      await until(() => phone.controller.nowPlaying.muted);
      expect(tv.display.player.muted, isTrue);

      tv.native.statsValue = const Media3Stats(
        position: Duration(seconds: 10),
        duration: Duration(seconds: 120),
      );
      await tv.display.seekBy(30000); // fast-forward
      await until(() => tv.native.calls.contains('seek:40000'));
      await tv.display.seekBy(-30000); // rewind: clamps at the start
      await until(() => tv.native.calls.contains('seek:0'));
    });

    test(
      'the TV reports its duration; a seek past the end clamps to it',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        tv.native.statsValue = const Media3Stats(
          position: Duration(seconds: 7),
          duration: Duration(seconds: 60),
        );
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);
        await until(() => tv.display.player.snapshot.durationMs == 60000);
        // Let the position report that carries the duration reach the Pi.
        await untilAsync(() async => (await piPlayer())['positionMs'] != 0);

        await phone.controller.seekBy(10 * 60 * 1000);
        await until(() => tv.native.calls.contains('seek:60000'));
        await until(() => phone.controller.nowPlaying.positionMs == 60000);
      },
    );

    test(
      'an item that ends makes the Pi move on, wrapping at the end',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);

        for (var i = 2; i <= 4; i++) {
          tv.native.onEnded!();
          await until(() => tv.native.opens.length == i);
        }
        expect(
          [for (final o in tv.native.opens) o.url.split('/')[4]],
          ['a.mp4', 'b.mp4', 'c.mp4', 'a.mp4'],
        );
        await until(() => phone.controller.nowPlaying.itemId == 'a.mp4');
      },
    );

    test('an item that cannot be played is skipped after a moment', () async {
      final tv = newTv();
      await tv.start();
      final phone = await pairPhone(tv);
      tv.native.statsValue = const Media3Stats(error: 'SOURCE: 404');
      await phone.controller.play();
      await until(() => tv.native.opens.length >= 2);
      expect(tv.native.opens[1].url, endsWith('/media/b.mp4/full'));
    });

    test('a phone gets "TV not connected" while the TV is away', () async {
      final tv = newTv();
      await tv.start();
      final phone = await pairPhone(tv);
      tv.dispose();
      await until(() => rig.display!.onlineDisplayId == null);

      await phone.controller.play();
      expect(phone.controller.tvNotConnected, isTrue);
      expect(phone.controller.nowPlaying.isIdle, isTrue);
    });
  });

  group('Pi restart and offline', () {
    test(
      'the TV reconnects, reports, and the picture does not restart',
      () async {
        final dir = tempDir = Directory.systemTemp.createTempSync('tv_restart');
        final file = '${dir.path}/hub.db';
        await rig.dispose();
        rig = await Rig.start(dbFile: file, playlists: playlists);

        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        tv.native.statsValue = const Media3Stats(
          position: Duration(seconds: 5),
          duration: Duration(seconds: 60),
        );
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);
        await until(() => tv.display.player.snapshot.durationMs == 60000);

        final port = rig.server.port;
        await rig.dispose();
        await until(() => !tv.display.connected);
        rig = await Rig.start(dbFile: file, port: port, playlists: playlists);

        await until(() => tv.display.connected);
        // The fresh Pi knows nothing until the TV's report arrives.
        await untilAsync(() async => (await piPlayer())['itemId'] == 'a.mp4');
        final p = await piPlayer();
        expect(p['state'], 'playing');
        expect(p['positionMs'] as int, greaterThanOrEqualTo(5000));
        // The picture was never reopened.
        expect(tv.native.opens, hasLength(1));
        expect(tv.native.calls, isNot(contains('release')));
        // The phone reconnects and shows the same item.
        await until(() => phone.controller.nowPlaying.itemId == 'a.mp4');
      },
    );

    test(
      'without the Pi the item loops locally and nothing is asked',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);

        await rig.dispose();
        await until(() => !tv.display.connected);
        tv.native.onEnded!();
        await until(() => tv.native.calls.contains('resume'));
        expect(tv.native.calls, containsAllInOrder(['seek:0', 'resume']));
        expect(tv.native.opens, hasLength(1));
        // The remote does nothing while the Pi is away (and does not throw).
        await tv.display.next();
        await tv.display.togglePause();
        // A rig for tearDown to dispose.
        rig = await Rig.start(playlists: playlists);
      },
    );

    test(
      'the view going away and coming back reopens at the same place',
      () async {
        final tv = newTv();
        await tv.start();
        final phone = await pairPhone(tv);
        tv.native.statsValue = const Media3Stats(
          position: Duration(seconds: 12),
          duration: Duration(seconds: 60),
        );
        await phone.controller.play();
        await until(() => tv.native.opens.length == 1);

        await tv.display.player.viewDisposed(); // Menu opens
        expect(tv.native.calls, contains('release'));
        await tv.display.player.viewCreated(); // Menu closes
        expect(tv.native.opens, hasLength(2));
        expect(tv.native.opens.last.url, tv.native.opens.first.url);
        expect(tv.native.opens.last.startMs, 12000);
      },
    );
  });
}
