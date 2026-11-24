import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tv_saver/tv/menu_screen.dart';
import 'package:tv_saver/tv/update/update_screen.dart';
import 'package:tv_saver/tv/update/update_source_store.dart';
import 'package:tv_saver/tv/update/updater.dart';

void main() {
  late Directory dir;
  late MemoryUpdateSourceStore store;
  late List<String> installed;
  late List<Uri> fetched;
  var installedCode = 1;
  final apkBytes = utf8.encode('apk');
  final apkSha = sha256.convert(apkBytes).toString();

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('upscr');
    store = MemoryUpdateSourceStore('http://10.0.0.5:8099/update.json');
    installed = [];
    fetched = [];
    installedCode = 1;
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the downloaded file for a moment.
    }
  });

  /// Lets real I/O finish (the download and the checksum) until [done].
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 40 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await tester.pump();
  }

  TvUpdater make({int serverCode = 2}) => TvUpdater(
    store: store,
    installedVersionCode: () async => installedCode,
    fetch: (uri) async {
      fetched.add(uri);
      return '{"versionCode": $serverCode, "versionName": "0.2.0", '
          '"apk": "tv-saver-tv.apk", "sha256": "$apkSha"}';
    },
    download: (uri, file, onProgress) async {
      onProgress(0.5);
      await file.writeAsBytes(apkBytes);
    },
    installer: (path) async {
      installed.add(path);
      return InstallResult.started;
    },
    tempDir: () async => dir,
  );

  Future<void> pumpScreen(WidgetTester tester, TvUpdater updater) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateScreen(updater: updater, version: '0.1.0 (1)'),
      ),
    );
    // The saved address loads and the first check runs.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  String headline(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('update-headline'))).data!;

  testWidgets('opens with a check: shows the saved address and the update', (
    tester,
  ) async {
    await pumpScreen(tester, make());
    expect(find.text('Installed: 0.1.0 (1)'), findsOneWidget);
    expect(headline(tester), 'Version 0.2.0 is ready');
    final field = tester.widget<TextField>(
      find.byKey(const Key('update-address')),
    );
    expect(field.controller!.text, 'http://10.0.0.5:8099/update.json');
    expect(find.textContaining('OK: install'), findsOneWidget);
    expect(fetched.single.toString(), 'http://10.0.0.5:8099/update.json');
  });

  testWidgets('OK installs: download, check, system installer', (tester) async {
    await pumpScreen(tester, make());
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await until(tester, () => installed.isNotEmpty);
    expect(installed, hasLength(1));
    expect(headline(tester), 'Installing version 0.2.0…');
  });

  testWidgets('up to date says so; OK checks again', (tester) async {
    installedCode = 5;
    await pumpScreen(tester, make());
    expect(headline(tester), 'Up to date');
    expect(find.textContaining('OK: check again'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(fetched, hasLength(2));
  });

  testWidgets('an unreachable server is said plainly', (tester) async {
    final updater = TvUpdater(
      store: store,
      installedVersionCode: () async => 1,
      fetch: (_) async => throw const SocketException('no route'),
      tempDir: () async => dir,
    );
    await pumpScreen(tester, updater);
    expect(headline(tester), 'No update found');
    expect(
      find.textContaining('Could not reach the update server'),
      findsOneWidget,
    );
  });

  testWidgets('Up edits the address; a bad one is refused, a good one saved', (
    tester,
  ) async {
    await pumpScreen(tester, make());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('update-address')),
    );
    await tester.runAsync(() async {
      field.onSubmitted!('   ');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining('Invalid address'), findsOneWidget);

    await tester.runAsync(() async {
      field.onSubmitted!('192.168.1.20:8099');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    expect(await store.updateSource(), 'http://192.168.1.20:8099/update.json');
    expect(find.textContaining('Invalid address'), findsNothing);
  });

  testWidgets('back from the installer without the new version offers it '
      'again', (tester) async {
    await pumpScreen(tester, make());
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await until(tester, () => installed.isNotEmpty);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(headline(tester), 'The update did not work');
    expect(find.textContaining('Press Install to try again'), findsOneWidget);
  });

  testWidgets('the menu says an update is ready and Down opens the screen', (
    tester,
  ) async {
    final updater = make();
    await updater.check();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvMenuScreen(version: '0.1.0 (1)', updater: updater),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('menu-update-hint'))).data,
      'Version 0.2.0 is ready: press Down',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byType(UpdateScreen), findsOneWidget);
  });

  testWidgets('without an updater the menu has no update key', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: TvMenuScreen(version: '0.1.0 (1)')),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('menu-update-hint')), findsNothing);
  });
}
