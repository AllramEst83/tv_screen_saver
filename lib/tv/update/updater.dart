import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hub_core/hub_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'update_source_store.dart';

enum UpdatePhase {
  none,
  available,
  downloading,
  installing,
  needsPermission,
  error,
  checking,
  upToDate,
  checkFailed,
}

class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.none,
    this.versionName,
    this.progress = 0,
    this.message,
  });

  final UpdatePhase phase;
  final String? versionName;
  final double progress;
  final String? message;

  bool get canInstall =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.needsPermission ||
      (phase == UpdatePhase.error && versionName != null);
}

enum InstallResult { started, needsPermission, failed }

const kMaxManifestBytes = 64 * 1024;
const kMaxApkBytes = 500 * 1024 * 1024;

typedef FetchText = Future<String> Function(Uri uri);
typedef DownloadFile = Future<void> Function(
  Uri uri,
  File target,
  void Function(double) onProgress,
);
typedef OpenInstaller = Future<InstallResult> Function(String path);

/// LAN self-updater of the TV app (story 6-1): asks the update server on the
/// desktop PC (`tool/serve_tv_update.dart`) for `update.json`, downloads the
/// APK, checks its sha256 and opens the system installer.
class TvUpdater {
  TvUpdater({
    required this.store,
    Future<int> Function()? installedVersionCode,
    FetchText? fetch,
    DownloadFile? download,
    OpenInstaller? installer,
    Future<Directory> Function()? tempDir,
  }) : _installedVersionCode = installedVersionCode ?? _platformVersionCode,
       _fetch = fetch ?? _httpFetch,
       _download = download ?? _httpDownload,
       _installer = installer ?? _platformInstaller,
       _tempDir = tempDir ?? getTemporaryDirectory;

  final UpdateSourceStore store;
  final Future<int> Function() _installedVersionCode;
  final FetchText _fetch;
  final DownloadFile _download;
  final OpenInstaller _installer;
  final Future<Directory> Function() _tempDir;

  final state = ValueNotifier<UpdateState>(const UpdateState());
  final sourceUrl = ValueNotifier<String?>(null);

  Uri? _manifestUri;
  UpdateManifest? _manifest;

  /// Normalizes a user-typed update address: adds `http://` if scheme is missing
  /// and `/update.json` if only host:port was entered.
  static String normalizeAddress(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null && (uri.path.isEmpty || uri.path == '/')) {
      trimmed = uri.replace(path: '/update.json').toString();
    }
    return trimmed;
  }

  Future<void> loadSavedSource() async {
    sourceUrl.value = await store.updateSource();
  }

  /// Saves the update address and immediately runs a visible check so the TV
  /// shows live feedback (available, up-to-date, or unreachable).
  Future<String> setSource(String url) async {
    final normalized = normalizeAddress(url);
    if (!isValidUpdateAddress(normalized)) {
      throw const FormatException(
        'Invalid address. Example: http://192.168.1.20:8099/update.json',
      );
    }
    await store.setUpdateSource(normalized);
    sourceUrl.value = normalized;
    unawaited(checkNow());
    return normalized;
  }

  Future<void> check() => _check(report: false);
  Future<void> checkNow() => _check(report: true);

  bool get _busyInstalling =>
      state.value.phase == UpdatePhase.downloading ||
      state.value.phase == UpdatePhase.installing;

  Future<void> _check({required bool report}) async {
    final phase = state.value.phase;
    if (phase == UpdatePhase.downloading ||
        phase == UpdatePhase.installing ||
        phase == UpdatePhase.checking) {
      return;
    }
    final saved = await store.updateSource();
    if (_busyInstalling) return;
    sourceUrl.value = saved;
    final uri = saved == null ? null : Uri.tryParse(saved);
    if (uri == null || !isValidUpdateAddress(saved!)) {
      if (report) {
        state.value = const UpdateState(
          phase: UpdatePhase.checkFailed,
          message: 'Enter the update address',
        );
      }
      return;
    }
    if (report) {
      state.value = UpdateState(
        phase: UpdatePhase.checking,
        message: 'Connecting to $saved...',
      );
    }
    try {
      final body = await _fetch(uri);
      if (_busyInstalling) return;
      final manifest = UpdateManifest.tryParse(body);
      if (manifest == null || manifest.apkUri(uri) == null) {
        if (report) {
          state.value = UpdateState(
            phase: UpdatePhase.checkFailed,
            message: 'Invalid reply from $saved (no update.json).',
          );
        }
        return;
      }
      final installed = await _installedVersionCode();
      if (_busyInstalling) return;
      if (!manifest.isNewerThan(installed)) {
        state.value = report
            ? UpdateState(
                phase: UpdatePhase.upToDate,
                message:
                    'You have the latest version (${manifest.versionName})',
              )
            : const UpdateState();
        return;
      }
      _manifestUri = uri;
      _manifest = manifest;
      state.value = UpdateState(
        phase: UpdatePhase.available,
        versionName: manifest.versionName,
        message: 'Version ${manifest.versionName} is ready to install',
      );
    } catch (_) {
      if (report && !_busyInstalling) {
        state.value = UpdateState(
          phase: UpdatePhase.checkFailed,
          message: 'Could not reach the update server at $saved',
        );
      }
    }
  }

  Future<void> installerClosed() async {
    if (state.value.phase != UpdatePhase.installing) return;
    final manifest = _manifest;
    int? installed;
    try {
      installed = await _installedVersionCode();
    } catch (_) {
      // Unknown: treat as not installed so Install is offered again.
    }
    if (state.value.phase != UpdatePhase.installing) return;
    if (installed != null &&
        manifest != null &&
        !manifest.isNewerThan(installed)) {
      state.value = const UpdateState();
      return;
    }
    state.value = UpdateState(
      phase: UpdatePhase.error,
      versionName: state.value.versionName,
      message: 'The update was not installed. Press Install to try again.',
    );
  }

  Future<void> install() async {
    final manifest = _manifest;
    final manifestUri = _manifestUri;
    if (manifest == null || manifestUri == null || !state.value.canInstall) {
      return;
    }
    final apkUri = manifest.apkUri(manifestUri);
    if (apkUri == null) return;
    final name = manifest.versionName;
    final expected = manifest.sha256;
    if (expected == null) {
      state.value = UpdateState(
        phase: UpdatePhase.error,
        versionName: name,
        message: 'This update has no checksum, so it was not installed',
      );
      return;
    }
    state.value = UpdateState(
      phase: UpdatePhase.downloading,
      versionName: name,
    );
    File? file;
    try {
      final dir = await _tempDir();
      file = File('${dir.path}${Platform.pathSeparator}tv-saver-update.apk');
      var reuse = false;
      if (file.existsSync()) {
        reuse =
            (await sha256.bind(file.openRead()).first).toString() == expected;
      }
      if (!reuse) {
        if (file.existsSync()) file.deleteSync();
        await _download(
          apkUri,
          file,
          (p) => state.value = UpdateState(
            phase: UpdatePhase.downloading,
            versionName: name,
            progress: p,
          ),
        );
      }
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected) {
        file.deleteSync();
        state.value = UpdateState(
          phase: UpdatePhase.error,
          versionName: name,
          message: 'Download damaged, try again',
        );
        return;
      }
      switch (await _installer(file.path)) {
        case InstallResult.started:
          state.value = UpdateState(
            phase: UpdatePhase.installing,
            versionName: name,
          );
        case InstallResult.needsPermission:
          state.value = UpdateState(
            phase: UpdatePhase.needsPermission,
            versionName: name,
            message:
                'Allow TV Saver to install apps, then press Install again.',
          );
        case InstallResult.failed:
          state.value = UpdateState(
            phase: UpdatePhase.error,
            versionName: name,
            message: 'Could not open the system installer.',
          );
      }
    } catch (_) {
      _deleteQuietly(file);
      state.value = UpdateState(
        phase: UpdatePhase.error,
        versionName: name,
        message: 'Could not download the update.',
      );
    }
  }
}

void _deleteQuietly(File? file) {
  try {
    if (file != null && file.existsSync()) file.deleteSync();
  } catch (_) {}
}

const kNetworkStall = Duration(seconds: 15);

Future<int> _platformVersionCode() async =>
    int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

Future<String> _httpFetch(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode != 200) throw const HttpException('status');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 3))) {
      bytes.addAll(chunk);
      if (bytes.length > kMaxManifestBytes) {
        throw const HttpException('too large');
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

/// Downloads [uri] to [target]. Progress is 0..1, or -1 when the server did
/// not send a length (the UI shows an indeterminate bar). Any failure,
/// including a 15 s stall, deletes the partial file.
Future<void> _httpDownload(
  Uri uri,
  File target,
  void Function(double) onProgress,
) async {
  final client = HttpClient()..connectionTimeout = kNetworkStall;
  try {
    final request = await client.getUrl(uri).timeout(kNetworkStall);
    final response = await request.close().timeout(kNetworkStall);
    if (response.statusCode != 200) throw const HttpException('status');
    final total = response.contentLength;
    if (total > kMaxApkBytes) throw const HttpException('too large');
    if (total <= 0) onProgress(-1);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.timeout(kNetworkStall)) {
        received += chunk.length;
        if (received > kMaxApkBytes) throw const HttpException('too large');
        sink.add(chunk);
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await sink.close();
    }
  } catch (_) {
    _deleteQuietly(target);
    rethrow;
  } finally {
    client.close(force: true);
  }
}

const _installerChannel = MethodChannel('tvsaver/installer');

Future<InstallResult> _platformInstaller(String path) async {
  try {
    return switch (await _installerChannel.invokeMethod<String>('install', {
      'path': path,
    })) {
      'started' => InstallResult.started,
      'needs_permission' => InstallResult.needsPermission,
      _ => InstallResult.failed,
    };
  } on PlatformException {
    return InstallResult.failed;
  } on MissingPluginException {
    return InstallResult.failed;
  }
}
