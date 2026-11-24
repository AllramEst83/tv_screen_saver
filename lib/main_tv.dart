import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hub_core/hub_core.dart';

import 'shared/secure_token_store.dart';
import 'tv/cache/media_cache.dart';
import 'tv/cache/storage.dart';
import 'tv/display/playback_log.dart';
import 'tv/update/update_source_store.dart';
import 'tv/update/updater.dart';
import 'tv/display/display_client.dart';
import 'tv/display/display_native.dart';
import 'tv/display/display_screen.dart';
import 'tv/display_report.dart';
import 'tv/menu_screen.dart';
import 'tv/video_spike/spike_log.dart';
import 'tv/video_spike/spike_native.dart';

/// TV app entry point (flavor `tv`, `com.codedbykay.tvsaver.tv`).
///
/// The TV is the paired display of the Pi: it shows the pairing QR while no
/// phone is paired and plays what the Pi tells it. The Menu key opens the
/// DisplayReport and the earlier spikes.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  var version = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    version = '${info.version} (${info.buildNumber})';
  } catch (e) {
    debugPrint('TV Saver: version unavailable: $e');
  }
  debugPrint('TV Saver: version $version');

  // The true panel size from the native display mode; a `wm size` override
  // shrinks `view.display.size`, so that is only the fallback.
  final panel = await DisplayReport.fetchPanelSize();
  if (panel == null) {
    debugPrint('TV Saver: native panel size unavailable, panel unverified');
  }

  // Story 1-2: what the TV can decode (HEVC profiles, AC-3 / E-AC-3).
  unawaited(logVideoDecoders(const ChannelSpikeNative()));

  // Decoded pictures: current, next and the one fading out (about 100 MB at
  // 3840x2160), within the 160 MB budget of media-fidelity.md.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 160 * 1024 * 1024
    ..maximumSize = 8;

  final cache = await _openCache();
  final log = await _openLog();
  final updater = await _openUpdater();
  final store = SecureTokenStore();
  final display = DisplayClient(
    client: HubClient(
      tokenStore: store,
      clientName: 'TV',
      kind: 'display',
      // A new TV may wait for a phone to approve it (the Pi allows 120 s).
      handshakeTimeout: const Duration(seconds: 125),
    ),
    store: store,
    native: ChannelDisplayNative(),
    cache: cache,
  );

  runApp(
    TvSaverApp(
      version: version,
      panel: panel,
      homeBuilder: (context) => DisplayScreen(
        client: display,
        log: log,
        menuBuilder: (ctx, onPairPhone) => Scaffold(
          backgroundColor: Colors.black,
          body: TvMenuScreen(
            version: version,
            panel: panel,
            onPairPhone: onPairPhone,
            updater: updater,
          ),
        ),
      ),
    ),
  );
}

class TvSaverApp extends StatelessWidget {
  const TvSaverApp({
    super.key,
    required this.version,
    this.panel,
    this.homeBuilder,
  });

  final String version;

  /// Native panel size from [DisplayReport.fetchPanelSize]; null falls back
  /// to `view.display.size` (marked "panel unverified").
  final PanelSize? panel;

  /// The home screen; null shows the menu (DisplayReport and the spikes).
  final WidgetBuilder? homeBuilder;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Saver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Builder(
          builder:
              homeBuilder ??
              (_) => TvMenuScreen(version: version, panel: panel),
        ),
      ),
    );
  }
}

/// The TV's media cache in the app's own files directory (never the shared
/// storage); null when the directory cannot be found, so everything streams.
Future<MediaCache?> _openCache() async {
  try {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/media-cache');
    final cache = MediaCache(dir: dir, freeBytes: () => freeBytesOf(base.path));
    await cache.cleanPartial();
    // Give back whatever the TV needs for itself before anything else.
    await cache.trim();
    return cache;
  } catch (e) {
    debugPrint('TV Saver: no media cache: $e');
    return null;
  }
}

/// The playback log in the app's external files directory, where `adb pull`
/// can read it (`Android/data/<package>/files/log/playback.csv`).
Future<PlaybackLog> _openLog() async {
  try {
    final dir =
        await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    return FilePlaybackLog(File('${dir.path}/log/playback.csv'));
  } catch (e) {
    debugPrint('TV Saver: no playback log: $e');
    return const NoPlaybackLog();
  }
}

/// The self-updater (story 6-1) with its address remembered in the app's own
/// directory. A quiet check at start finds out whether an update is waiting;
/// the Menu screen then says so. Null when the directory cannot be found.
Future<TvUpdater?> _openUpdater() async {
  try {
    final base = await getApplicationSupportDirectory();
    final updater = TvUpdater(
      store: FileUpdateSourceStore(File('${base.path}/update-source.txt')),
    );
    await updater.loadSavedSource();
    unawaited(updater.check());
    return updater;
  } catch (e) {
    debugPrint('TV Saver: no updater: $e');
    return null;
  }
}
