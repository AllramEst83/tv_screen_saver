import 'dart:async';
import 'dart:io';

import 'package:hub_core/hub_core.dart';
import 'package:test/test.dart';

import 'support/fake_phone_harness.dart';

const _token = 'secret-token';

void main() {
  late Directory tmp;
  late PiServer server;
  late HttpClient http;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hubadmin');
    File(
      '${tmp.path}/clip',
    ).writeAsBytesSync(List.generate(1000, (i) => i % 251));
    server = PiServer(
      ServerConfig(
        mediaDir: tmp.path,
        tokenFile: '${tmp.path}/token',
        port: 0,
        serverId: 'test',
      ),
      _token,
    );
    await server.start(address: '0.0.0.0');
    http = HttpClient();
  });

  tearDown(() async {
    http.close(force: true);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<int> request(
    String method,
    String path, {
    String? bearer,
    Map<String, String> headers = const {},
    String host = '127.0.0.1',
  }) async {
    final req = await http.openUrl(
      method,
      Uri.parse('http://$host:${server.port}$path'),
    );
    if (bearer != null) req.headers.set('Authorization', 'Bearer $bearer');
    headers.forEach(req.headers.set);
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  Future<TestPhone> pairDisplay() async {
    final tv = await TestPhone.connect(server.port);
    await tv.helloAsDisplay();
    return tv;
  }

  group('media auth', () {
    test('a paired device token streams media with Range', () async {
      final tv = await pairDisplay();
      addTearDown(tv.close);
      expect(await request('GET', '/media/clip', bearer: tv.token), 404);
      expect(await request('GET', '/media/clip/full', bearer: tv.token), 200);
      expect(
        await request(
          'GET',
          '/media/clip/full',
          bearer: tv.token,
          headers: {'Range': 'bytes=10-19'},
        ),
        206,
      );
    });

    test('static token still works; unknown or missing token is 401', () async {
      expect(await request('GET', '/media/clip/full', bearer: _token), 200);
      expect(await request('GET', '/media/clip/full', bearer: 'nope'), 401);
      expect(await request('GET', '/media/clip/full'), 401);
    });

    test('a forgotten device token stops working', () async {
      final tv = await pairDisplay();
      addTearDown(tv.close);
      expect(await request('GET', '/media/clip/full', bearer: tv.token), 200);
      await server.hub.resetAll();
      expect(await request('GET', '/media/clip/full', bearer: tv.token), 401);
    });
  });

  group('admin reset-pairings', () {
    test('loopback POST with the token deletes all devices', () async {
      final tv = await pairDisplay();
      addTearDown(tv.close);
      expect(await server.db.allDevices(), hasLength(1));

      expect(
        await request('POST', '/admin/reset-pairings', bearer: _token),
        200,
      );
      expect(await server.db.allDevices(), isEmpty);
      await until(() => tv.closed);
    });

    test('wrong or missing token is 401 and changes nothing', () async {
      final tv = await pairDisplay();
      addTearDown(tv.close);
      expect(
        await request('POST', '/admin/reset-pairings', bearer: 'bad'),
        401,
      );
      expect(await request('POST', '/admin/reset-pairings'), 401);
      // A paired device token is not an admin token.
      expect(
        await request('POST', '/admin/reset-pairings', bearer: tv.token),
        401,
      );
      expect(await server.db.allDevices(), hasLength(1));
      expect(tv.closed, isFalse);
    });

    test('GET is not allowed', () async {
      expect(
        await request('GET', '/admin/reset-pairings', bearer: _token),
        405,
      );
    });

    test('non-loopback peers get 403', () async {
      final lan = <String>[];
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in i.addresses) {
          if (!a.isLoopback) lan.add(a.address);
        }
      }
      if (lan.isEmpty) {
        markTestSkipped('no non-loopback IPv4 address on this machine');
        return;
      }
      expect(
        await request(
          'POST',
          '/admin/reset-pairings',
          bearer: _token,
          host: lan.first,
        ),
        403,
      );
    });

    test('CLI with the server running resets over loopback', () async {
      final tv = await pairDisplay();
      addTearDown(tv.close);
      File('${tmp.path}/token').writeAsStringSync('$_token\n');
      final result = await resetPairings(
        ServerConfig(
          mediaDir: tmp.path,
          tokenFile: '${tmp.path}/token',
          port: server.port,
        ),
      );
      expect(result.ok, isTrue, reason: result.message);
      expect(await server.db.allDevices(), isEmpty);
      await until(() => tv.closed);

      // Display and phone start over: first display, first phone is owner.
      final tv2 = await pairDisplay();
      addTearDown(tv2.close);
      expect(tv2.role, 'display');
      final start = await tv2.startPairing();
      final phone = await TestPhone.connect(server.port);
      addTearDown(phone.close);
      await phone.pairWithQr(start['qr'] as String);
      expect(phone.role, 'owner');
    });

    test('CLI with a wrong token fails', () async {
      File('${tmp.path}/token').writeAsStringSync('wrong\n');
      final result = await resetPairings(
        ServerConfig(
          mediaDir: tmp.path,
          tokenFile: '${tmp.path}/token',
          port: server.port,
        ),
      );
      expect(result.ok, isFalse);
    });
  });

  group('admin reset-pairings without a running server', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('hubadmindb');
      File('${dir.path}/token').writeAsStringSync(_token);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<int> freePort() async {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      return port;
    }

    test('deletes the rows in the database file', () async {
      final path = '${dir.path}/hub.db';
      final db = HubDatabase.open(path);
      await db.insertDevice(id: 'd1', name: 'Phone', role: 'owner', nowMs: 1);
      await db.insertPairing(
        rawToken: 'abc',
        deviceId: 'd1',
        clientName: 'Phone',
        nowMs: 1,
      );
      await db.close();

      final result = await runAdminCommand(
        ['admin', 'reset-pairings'],
        ServerConfig(
          mediaDir: dir.path,
          tokenFile: '${dir.path}/token',
          dbFile: path,
          port: await freePort(),
        ),
      );
      expect(result!.ok, isTrue, reason: result.message);

      final check = HubDatabase.open(path);
      expect(await check.allDevices(), isEmpty);
      expect(await check.allPairings(), isEmpty);
      await check.close();
    });

    test('missing database file gives a message and failure', () async {
      final result = await resetPairings(
        ServerConfig(
          mediaDir: dir.path,
          tokenFile: '${dir.path}/token',
          dbFile: '${dir.path}/missing.db',
          port: await freePort(),
        ),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('No database file'));
      expect(File('${dir.path}/missing.db').existsSync(), isFalse);
    });

    test(
      'unknown admin command is a usage error; other args are not admin',
      () async {
        final config = ServerConfig(mediaDir: '.', tokenFile: 't');
        final bad = await runAdminCommand(['admin', 'nope'], config);
        expect(bad!.ok, isFalse);
        expect(await runAdminCommand(const [], config), isNull);
      },
    );
  });
}

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
