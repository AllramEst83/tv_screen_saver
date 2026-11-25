import 'package:hub_core/hub_core.dart';
import 'package:tv_saver/tv/cache/media_cache.dart';
import 'package:tv_saver/tv/display/display_client.dart';
import 'package:tv_saver/tv/display/display_native.dart';
import 'package:tv_saver/tv/video_spike/spike_native.dart';

import '../phone/support.dart';

/// One `open` call the player made.
typedef FakeOpen = ({
  String url,
  Map<String, String> headers,
  int startMs,
  bool muted,
  bool playing,
  bool loop,
});

/// [DisplayVideoNative] that records what the player asked and answers
/// [statsValue].
class FakeDisplayNative implements DisplayVideoNative {
  final List<FakeOpen> opens = [];

  /// `pause`, `resume`, `seek:<ms>`, `mute:<bool>`, `release`.
  final List<String> calls = [];

  Media3Stats? statsValue = const Media3Stats();

  /// What `showImage` answers (a TV that cannot draw photos natively: false).
  bool imageSupported = true;
  final List<({String path, int crossfadeMs, bool kenBurns, int durationMs})>
  shows = [];

  @override
  void Function()? onEnded;

  @override
  Future<List<String>> decoders() async => ['hevc'];

  @override
  Future<DisplayModeInfo?> displayInfo() async => const DisplayModeInfo(
    modeId: 1,
    width: 3840,
    height: 2160,
    refreshRate: 60,
    hdrTypes: [2],
  );

  @override
  Future<void> open({
    required String url,
    required Map<String, String> headers,
    int startMs = 0,
    bool muted = false,
    bool playing = true,
    bool loop = false,
  }) async {
    opens.add((
      url: url,
      headers: headers,
      startMs: startMs,
      muted: muted,
      playing: playing,
      loop: loop,
    ));
  }

  @override
  Future<bool> showImage({
    required String path,
    int crossfadeMs = 0,
    bool kenBurns = false,
    int durationMs = 0,
  }) async {
    shows.add((
      path: path,
      crossfadeMs: crossfadeMs,
      kenBurns: kenBurns,
      durationMs: durationMs,
    ));
    return imageSupported;
  }

  @override
  Future<void> clearImage() async => calls.add('clearImage');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> seek(int positionMs) async => calls.add('seek:$positionMs');

  @override
  Future<void> setMuted(bool muted) async => calls.add('mute:$muted');

  @override
  Future<Media3Stats?> stats() async => statsValue;

  @override
  Future<void> release() async => calls.add('release');
}

/// A TV: display client, fake native player and an in-memory token store,
/// wired like `main_tv.dart` against the hub of [rig].
class TvRig {
  TvRig(
    Rig rig, {
    HubTokenStore? store,
    Duration positionInterval = const Duration(milliseconds: 100),
    Duration handshakeTimeout = const Duration(seconds: 20),
    MediaCache? cache,
    String render = '3840x2160',
  }) : store = store ?? MemoryHubTokenStore(),
       lock = FakeLock(),
       native = FakeDisplayNative() {
    endpoint = HubEndpoint(
      host: '127.0.0.1',
      port: rig.server.port,
      name: 'Test Pi',
      id: 'hub-phone-test',
    );
    client = HubClient(
      tokenStore: this.store,
      clientName: 'Test TV',
      kind: 'display',
      handshakeTimeout: handshakeTimeout,
      scanner: FakeScanner([endpoint]),
      directTimeout: const Duration(milliseconds: 400),
      mdnsTimeout: const Duration(milliseconds: 400),
      reconnectBackoff: const [Duration(milliseconds: 100)],
    );
    display = DisplayClient(
      client: client,
      store: this.store,
      native: native,
      cache: cache,
      scanner: FakeScanner([endpoint]),
      lock: lock,
      capabilities: () async => {
        'decoders': ['hevc'],
        'hdr': ['HDR10'],
        'render': render,
        'panel': '3840x2160',
      },
      positionInterval: positionInterval,
      statsInterval: const Duration(milliseconds: 50),
      errorRetry: const Duration(milliseconds: 200),
      retryDelay: const Duration(milliseconds: 100),
      anchorDelay: const Duration(milliseconds: 100),
      approvalHintDelay: const Duration(milliseconds: 100),
    );
  }

  final HubTokenStore store;
  final FakeLock lock;
  final FakeDisplayNative native;
  late final HubEndpoint endpoint;
  late final HubClient client;
  late final DisplayClient display;

  /// Starts, waits until connected, and shows the (fake) video view.
  Future<void> start() async {
    await display.start();
    await until(() => display.connected);
    await display.player.viewCreated();
  }

  void dispose() => display.dispose();
}
