/// Stores lightweight hub metadata (stable hub ID, update URL, TV name).
abstract class TvStore {
  Future<String> hubId();
  Future<String?> updateSource();
  Future<void> setUpdateSource(String? url);
  Future<String?> tvName();
  Future<void> setTvName(String? name);
  Future<String?> settingsJson();
  Future<void> setSettingsJson(String? json);
}

class MemoryTvStore implements TvStore {
  MemoryTvStore([this._id = 'hub-test-01']);
  final String _id;
  String? _updateSource;
  String? _tvName;

  @override
  Future<String> hubId() async => _id;

  @override
  Future<String?> updateSource() async => _updateSource;

  @override
  Future<void> setUpdateSource(String? url) async => _updateSource = url;

  @override
  Future<String?> tvName() async => _tvName;

  @override
  Future<void> setTvName(String? name) async => _tvName = name;

  String? _settings;

  @override
  Future<String?> settingsJson() async => _settings;

  @override
  Future<void> setSettingsJson(String? json) async => _settings = json;
}
