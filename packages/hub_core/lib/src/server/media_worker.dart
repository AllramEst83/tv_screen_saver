import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Value;

import '../config.dart';
import '../db/hub_database.dart';
import 'media_probe.dart';
import 'tool_runner.dart';

/// The longest edge of a poster and of the `1920` image variant.
const kLargeEdge = 1920;

/// The longest edge of a `thumb`.
const kThumbEdge = 320;

const kProbeTimeout = Duration(seconds: 30);
const kImageTimeout = Duration(seconds: 60);

/// A tool failed, hung or could not read the file.
class MediaToolException implements Exception {
  const MediaToolException(this.reason);

  final String reason;

  @override
  String toString() => 'MediaToolException($reason)';
}

/// What `vipsheader` says about an image.
class ImageDims {
  const ImageDims(this.width, this.height);

  /// Size as displayed (EXIF orientation applied).
  final int width;
  final int height;
}

/// [w]x[h] scaled down to a long edge of [edge]; never upscaled. Even sizes
/// (video encoders want them).
(int, int) fitWithin(int w, int h, int edge) {
  final longest = max(w, h);
  if (longest <= edge) return (w - w % 2, h - h % 2);
  final k = edge / longest;
  int even(int v) => max(2, (v * k).round() & ~1);
  return (even(w), even(h));
}

String _firstLine(String s) {
  final line = s
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return line.length > 160 ? line.substring(0, 160) : line;
}

/// The probe and variant steps, on one file at a time. Used by the worker and
/// by `tool/probe.dart`.
class MediaTools {
  MediaTools(this.runner);

  final ToolRunner runner;

  /// `ffprobe` on a video.
  Future<ProbeInfo> probeVideo(String path, {int? fileBytes}) async {
    final r = await runner.run(
      'ffprobe',
      ffprobeArgs(path),
      timeout: kProbeTimeout,
    );
    if (r.timedOut) {
      throw const MediaToolException('ffprobe timed out after 30 s');
    }
    if (r.exitCode != 0) {
      final why = _firstLine(r.stderr);
      throw MediaToolException(
        why.isEmpty
            ? 'The video could not be read'
            : 'The video could not be read: $why',
      );
    }
    try {
      return parseFfprobe(r.stdout, fileBytes: fileBytes);
    } on ProbeException catch (e) {
      throw MediaToolException(e.reason);
    }
  }

  /// Size and orientation of an image through `vipsheader`.
  Future<ImageDims> probeImage(String path) async {
    final r = await runner.run('vipsheader', [
      '-a',
      path,
    ], timeout: kImageTimeout);
    if (r.timedOut) {
      throw const MediaToolException('vipsheader timed out after 60 s');
    }
    if (r.exitCode != 0) {
      final why = _firstLine(r.stderr);
      throw MediaToolException(
        why.isEmpty
            ? 'The image could not be read'
            : 'The image could not be read: $why',
      );
    }
    final fields = <String, String>{};
    for (final line in r.stdout.split('\n')) {
      final i = line.indexOf(':');
      if (i > 0) {
        fields[line.substring(0, i).trim()] = line.substring(i + 1).trim();
      }
    }
    var w = int.tryParse(fields['width'] ?? '');
    var h = int.tryParse(fields['height'] ?? '');
    if (w == null || h == null || w <= 0 || h <= 0) {
      throw const MediaToolException('The image has no size');
    }
    final orientation = int.tryParse(fields['orientation'] ?? '');
    if (orientation != null && orientation >= 5 && orientation <= 8) {
      final t = w;
      w = h;
      h = t;
    }
    return ImageDims(w, h);
  }

  Future<void> _delete(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Not there.
    }
  }

  Future<void> _ffmpeg(List<String> args, String out, String what) async {
    final r = await runner.run('ffmpeg', [
      '-nostdin',
      '-v',
      'error',
      '-y',
      ...args,
      out,
    ], timeout: kImageTimeout);
    if (r.timedOut) {
      await _delete(out);
      throw MediaToolException('ffmpeg timed out making the $what');
    }
    if (r.exitCode != 0 ||
        !await File(out).exists() ||
        await File(out).length() == 0) {
      await _delete(out);
      final why = _firstLine(r.stderr);
      throw MediaToolException(
        why.isEmpty
            ? 'The $what could not be made'
            : 'The $what could not be made: $why',
      );
    }
  }

  /// Makes `poster` (frame at 10 % of the duration, long edge <= 1920) and
  /// `thumb` (long edge 320, skipped for a poster that small) into
  /// `<outDir>/<id>.<variant>`. Returns the variants that now exist.
  Future<List<String>> videoVariants({
    required String source,
    required ProbeInfo info,
    required String outDir,
    required String id,
  }) async {
    await Directory(outDir).create(recursive: true);
    final posterTmp = '$outDir/$id.poster.tmp.jpg';
    final thumbTmp = '$outDir/$id.thumb.tmp.jpg';
    final made = <String>[];
    try {
      final (pw, ph) = fitWithin(info.width, info.height, kLargeEdge);
      final seek = info.durationMs == null
          ? 0.0
          : info.durationMs! * 0.1 / 1000;
      Future<void> poster(double at) => _ffmpeg(
        [
          '-ss',
          at.toStringAsFixed(3),
          '-i',
          source,
          '-frames:v',
          '1',
          '-vf',
          'scale=$pw:$ph:flags=lanczos,format=yuvj420p',
          '-q:v',
          '2',
        ],
        posterTmp,
        'poster',
      );
      try {
        await poster(seek);
      } on MediaToolException {
        if (seek == 0) rethrow;
        await poster(0); // a seek past the last keyframe
      }
      final makeThumb = max(pw, ph) > kThumbEdge;
      if (makeThumb) {
        final (tw, th) = fitWithin(pw, ph, kThumbEdge);
        await _ffmpeg(
          [
            '-i',
            posterTmp,
            '-vf',
            'scale=$tw:$th:flags=lanczos,format=yuvj420p',
            '-q:v',
            '4',
          ],
          thumbTmp,
          'thumbnail',
        );
      }
      await File(posterTmp).rename('$outDir/$id.poster');
      made.add('poster');
      if (makeThumb) {
        await File(thumbTmp).rename('$outDir/$id.thumb');
        made.add('thumb');
      }
      return made;
    } finally {
      await _delete(posterTmp);
      await _delete(thumbTmp);
    }
  }

  /// Makes `1920` and `thumb` into `<outDir>/<id>.<variant>` with libvips
  /// (orientation applied, ICC profile kept). A variant is skipped when the
  /// source is not larger than it or when the result is not smaller than the
  /// source file. Returns the variants that now exist.
  Future<List<String>> imageVariants({
    required String source,
    required ImageDims info,
    required int sourceBytes,
    required String outDir,
    required String id,
  }) async {
    await Directory(outDir).create(recursive: true);
    final longest = max(info.width, info.height);
    final made = <String>[];
    for (final (name, edge, quality) in const [
      ('1920', kLargeEdge, 92),
      ('thumb', kThumbEdge, 85),
    ]) {
      if (longest <= edge) continue;
      final tmp = '$outDir/$id.$name.tmp.jpg';
      try {
        // libvips 8.16 saves with `keep=icc` (profile kept, other metadata
        // dropped); older versions reject that option, so retry without it
        // (they keep the profile by default).
        Future<ToolResult> thumbnail(String options) => runner.run('vips', [
          'thumbnail',
          source,
          '$tmp[$options]',
          '$edge',
          '--height',
          '$edge',
          '--size',
          'down',
        ], timeout: kImageTimeout);
        var r = await thumbnail('Q=$quality,optimize_coding,keep=icc');
        if (!r.timedOut && r.exitCode != 0 && !await File(tmp).exists()) {
          r = await thumbnail('Q=$quality,optimize_coding');
        }
        if (r.timedOut) {
          throw MediaToolException('vips timed out making the $name image');
        }
        if (r.exitCode != 0 || !await File(tmp).exists()) {
          final why = _firstLine(r.stderr);
          throw MediaToolException(
            why.isEmpty
                ? 'The $name image could not be made'
                : 'The $name image could not be made: $why',
          );
        }
        if (name != 'thumb' && await File(tmp).length() >= sourceBytes) {
          continue; // as large as the source: serve `full` instead
        }
        await File(tmp).rename('$outDir/$id.$name');
        made.add(name);
      } finally {
        await _delete(tmp);
      }
    }
    return made;
  }
}

/// Runs `ffprobe`, `ffmpeg` and `vips` on library items in the background,
/// one job at a time: metadata, capability check, poster and image variants.
///
/// Without a tool the items stay `new` and the worker logs it once. When the
/// tool shows up later ([refreshTools]) the waiting items are queued.
class MediaWorker {
  MediaWorker({
    required this.config,
    required this.db,
    required ToolRunner runner,
    required this.pathOf,
    required this.variantsDir,
    required this.onUpdated,
    required this.capabilities,
    void Function(String message)? log,
  }) : runner = runner,
       tools = MediaTools(runner),
       _log = log ?? ((m) => stderr.writeln('tvsaver media: $m'));

  final ServerConfig config;
  final HubDatabase db;
  final ToolRunner runner;
  final MediaTools tools;

  /// Path of the stored file of an item id.
  final String Function(String id) pathOf;
  final String variantsDir;

  /// Called with the fresh row after a job changed an item.
  final void Function(LibraryItemRow row) onUpdated;

  /// What the TV reported, or null when no display has reported yet.
  final Map<String, Object?>? Function() capabilities;
  final void Function(String) _log;

  final Queue<String> _queue = Queue();
  final Set<String> _queued = {};
  final Set<String> _loggedMissing = {};
  final List<Completer<void>> _idle = [];
  bool _hasFfprobe = false;
  bool _hasFfmpeg = false;
  bool _hasVips = false;
  bool _started = false;
  bool _stopped = false;
  bool _running = false;
  bool _recheckPending = false;
  Future<void> _loop = Future.value();

  bool get hasFfprobe => _hasFfprobe;
  bool get hasFfmpeg => _hasFfmpeg;
  bool get hasVips => _hasVips;

  /// Probes the tools, then queues every item that still needs work.
  Future<void> start() async {
    _stopped = false;
    await _probeTools(logMissing: true);
    _started = true;
    await _queueWaiting(includeErrors: true);
  }

  /// Looks for tools again; queues the waiting items when one appeared.
  Future<void> refreshTools() async {
    final before = (_hasFfprobe, _hasFfmpeg, _hasVips);
    await _probeTools(logMissing: false);
    final after = (_hasFfprobe, _hasFfmpeg, _hasVips);
    if (after != before) await _queueWaiting(includeErrors: false);
  }

  Future<void> _probeTools({required bool logMissing}) async {
    _hasFfprobe = await runner.isAvailable('ffprobe');
    _hasFfmpeg = await runner.isAvailable('ffmpeg');
    _hasVips =
        await runner.isAvailable('vips') &&
        await runner.isAvailable('vipsheader');
    for (final (name, ok) in [
      ('ffprobe', _hasFfprobe),
      ('ffmpeg', _hasFfmpeg),
      ('vips', _hasVips),
    ]) {
      if (ok) {
        _loggedMissing.remove(name);
      } else if (_loggedMissing.add(name)) {
        _log(
          '$name is not installed: items that need it stay "new" '
          '(sudo apt install ffmpeg libvips-tools)',
        );
      }
    }
  }

  /// Whether [r] still has work for the worker.
  bool _needsWork(LibraryItemRow r, {required bool includeErrors}) {
    if (r.state == 'error') return includeErrors;
    if (r.state == 'new') return true;
    if (r.kind == 'video') {
      return r.codec == null || !_variants(r).contains('poster');
    }
    return false;
  }

  Future<void> _queueWaiting({required bool includeErrors}) async {
    try {
      for (final r in await db.allLibraryItems()) {
        if (_needsWork(r, includeErrors: includeErrors)) enqueue(r.id);
      }
    } catch (err) {
      if (!_stopped) _log('could not list the library: $err');
    }
  }

  /// Queues item [id] (once).
  void enqueue(String id) {
    if (_stopped || !_queued.add(id)) return;
    _queue.add(id);
    _pump();
  }

  /// Drops [id] from the queue (the item was deleted).
  void remove(String id) {
    if (_queued.remove(id)) _queue.remove(id);
  }

  /// Checks every probed video against the capabilities again.
  Future<void> recheck() {
    _recheckPending = true;
    _pump();
    return idle;
  }

  /// Completes when nothing is queued or running.
  Future<void> get idle {
    if (!_running && _queue.isEmpty && !_recheckPending) {
      return Future.value();
    }
    final c = Completer<void>();
    _idle.add(c);
    return c.future;
  }

  void _pump() {
    if (!_started || _stopped || _running) return;
    _running = true;
    _loop = _run();
  }

  Future<void> _run() async {
    try {
      while (!_stopped) {
        if (_recheckPending) {
          _recheckPending = false;
          try {
            await _recheck();
          } catch (err) {
            if (!_stopped) _log('recheck failed: $err');
          }
          continue;
        }
        if (_queue.isEmpty) break;
        final id = _queue.removeFirst();
        _queued.remove(id);
        try {
          await _process(id);
        } catch (err) {
          if (!_stopped) {
            _log('job for $id failed: $err');
            await _setError(id, 'The media worker failed: $err');
          }
        } finally {}
      }
    } finally {
      _running = false;
      for (final c in _idle) {
        if (!c.isCompleted) c.complete();
      }
      _idle.clear();
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _started = false;
    _queue.clear();
    _queued.clear();
    runner.cancelAll();
    await _loop.catchError((Object _) {});
  }

  // ---- upload hook ----

  /// One quick `ffprobe` for the upload path; null when the tool is missing
  /// or cannot read the file (the job records the error later).
  Future<ProbeInfo?> quickProbe(String path, {int? fileBytes}) async {
    if (!_hasFfprobe) return null;
    try {
      return await tools.probeVideo(path, fileBytes: fileBytes);
    } on MediaToolException {
      return null;
    }
  }

  /// Why a video must be refused: above the streaming ceiling and also larger
  /// than 25 % of the TV cache. Null when it can be stored.
  String? tooHeavyReason(ProbeInfo info, int bytes) {
    if (!isAboveCeiling(info.bitrate)) return null;
    if (bytes * 4 <= config.tvCacheBytes) return null;
    final mbps = (info.bitrate! / 1e6).toStringAsFixed(0);
    final gb = (bytes / 1e9).toStringAsFixed(1);
    return 'This video is $mbps Mbit/s and $gb GB: above the '
        '${config.streamCeilingMbps} Mbit/s streaming limit and too big to '
        'cache on the TV. Lower its bitrate or size on the PC and send it '
        'again.';
  }

  /// The bitrate is above the streaming ceiling.
  bool isAboveCeiling(int? bitrate) =>
      bitrate != null && bitrate > config.streamCeilingMbps * 1000000;

  // ---- jobs ----

  static List<String> _variants(LibraryItemRow r) =>
      r.variants.isEmpty ? const [] : r.variants.split(',');

  LibraryItemsCompanion _probeCompanion(ProbeInfo info) =>
      LibraryItemsCompanion(
        width: Value(info.width),
        height: Value(info.height),
        durationMs: Value(info.durationMs),
        codec: Value(info.codec),
        profile: Value(info.profile),
        hdr: Value(info.hdr),
        fps: Value(info.fps),
        bitrate: Value(info.bitrate),
        audioCodec: Value(info.audioCodec),
        cacheRequired: Value(isAboveCeiling(info.bitrate)),
      );

  /// The state a probed video has under the current capabilities.
  ({String state, String? reason}) _verdict(
    LibraryItemRow r,
    List<String> variants,
  ) {
    final caps = capabilities();
    if (caps == null) return (state: 'new', reason: null);
    final v = checkCapabilities(
      codec: r.codec,
      profile: r.profile,
      hdr: r.hdr,
      audioCodec: r.audioCodec,
      capabilities: caps,
    );
    if (!v.supported) return (state: 'unsupported', reason: v.reason);
    return variants.contains('poster')
        ? (state: 'ready', reason: null)
        : (state: 'new', reason: null);
  }

  Future<LibraryItemRow?> _write(
    String id,
    LibraryItemsCompanion c, {
    bool notify = false,
  }) async {
    if (await db.updateLibraryItemMedia(id, c) == 0) return null;
    final row = await db.libraryItem(id);
    if (row != null && notify && !_stopped) onUpdated(row);
    return row;
  }

  Future<void> _setError(String id, String reason) async {
    try {
      await _write(
        id,
        LibraryItemsCompanion(
          state: const Value('error'),
          stateReason: Value(reason),
        ),
        notify: true,
      );
    } catch (_) {
      // The database may be closing.
    }
  }

  Future<void> _deleteVariantFiles(String id) async {
    for (final v in const ['poster', 'thumb', '1920']) {
      for (final suffix in const ['', '.tmp.jpg']) {
        try {
          await File('$variantsDir/$id.$v$suffix').delete();
        } on FileSystemException {
          // Not there.
        }
      }
    }
  }

  Future<void> _process(String id) async {
    final row = await db.libraryItem(id);
    if (row == null) return;
    if (!await File(pathOf(id)).exists()) return;
    if (row.kind == 'video') {
      await _processVideo(row);
    } else {
      await _processImage(row);
    }
  }

  Future<void> _processVideo(LibraryItemRow row) async {
    final id = row.id;
    final path = pathOf(id);
    var cur = row;
    if (cur.codec == null) {
      if (!_hasFfprobe) return; // stays new
      final ProbeInfo info;
      try {
        info = await tools.probeVideo(path, fileBytes: cur.bytes);
      } on MediaToolException catch (e) {
        await _setError(id, e.reason);
        return;
      }
      final saved = await _write(id, _probeCompanion(info));
      if (saved == null) return; // deleted meanwhile
      cur = saved;
    }
    var variants = _variants(cur);
    String? failure;
    if (_hasFfmpeg && !variants.contains('poster')) {
      try {
        final made = await tools.videoVariants(
          source: path,
          info: ProbeInfo(
            width: cur.width!,
            height: cur.height!,
            durationMs: cur.durationMs,
            codec: cur.codec!,
            profile: cur.profile,
            hdr: cur.hdr ?? 'SDR',
            fps: cur.fps,
            bitrate: cur.bitrate,
            audioCodec: cur.audioCodec,
          ),
          outDir: variantsDir,
          id: id,
        );
        variants = made;
      } on MediaToolException catch (e) {
        failure = e.reason;
      }
    }
    if (await db.libraryItem(id) == null) {
      await _deleteVariantFiles(id); // deleted during the job
      return;
    }
    final verdict = _verdict(cur, variants);
    final state = verdict.state == 'unsupported' || failure == null
        ? verdict.state
        : 'error';
    final reason = state == 'error' ? failure : verdict.reason;
    final saved = await _write(
      id,
      LibraryItemsCompanion(
        variants: Value(variants.join(',')),
        state: Value(state),
        stateReason: Value(reason),
      ),
      notify: true,
    );
    if (saved == null) await _deleteVariantFiles(id);
  }

  Future<void> _processImage(LibraryItemRow row) async {
    final id = row.id;
    if (!_hasVips) return; // stays new
    final path = pathOf(id);
    try {
      final info = await tools.probeImage(path);
      final made = await tools.imageVariants(
        source: path,
        info: info,
        sourceBytes: row.bytes,
        outDir: variantsDir,
        id: id,
      );
      if (await db.libraryItem(id) == null) {
        await _deleteVariantFiles(id);
        return;
      }
      final saved = await _write(
        id,
        LibraryItemsCompanion(
          width: Value(info.width),
          height: Value(info.height),
          variants: Value(made.join(',')),
          state: const Value('ready'),
          stateReason: const Value(null),
        ),
        notify: true,
      );
      if (saved == null) await _deleteVariantFiles(id);
    } on MediaToolException catch (e) {
      if (await db.libraryItem(id) == null) {
        await _deleteVariantFiles(id);
        return;
      }
      await _setError(id, e.reason);
    }
  }

  Future<void> _recheck() async {
    for (final r in await db.allLibraryItems()) {
      if (_stopped) return;
      if (r.kind != 'video' || r.codec == null || r.state == 'error') continue;
      final verdict = _verdict(r, _variants(r));
      if (verdict.state == r.state && verdict.reason == r.stateReason) continue;
      await _write(
        r.id,
        LibraryItemsCompanion(
          state: Value(verdict.state),
          stateReason: Value(verdict.reason),
        ),
        notify: true,
      );
    }
  }
}
