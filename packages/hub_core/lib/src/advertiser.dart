/// Announces the hub on the LAN via mDNS.
abstract class TvAdvertiser {
  Future<void> start({
    required String name,
    required String id,
    required int port,
  });
  Future<void> stop();
}

/// No-op advertiser for tests and non-mDNS environments.
class NoopAdvertiser implements TvAdvertiser {
  bool running = false;
  @override
  Future<void> start({
    required String name,
    required String id,
    required int port,
  }) async {
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }
}
