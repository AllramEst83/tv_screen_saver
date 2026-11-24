import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What an external tool did.
class ToolResult {
  const ToolResult(
    this.exitCode,
    this.stdout,
    this.stderr, {
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  /// The tool ran past its timeout and was killed.
  final bool timedOut;

  bool get ok => exitCode == 0 && !timedOut;
}

/// Runs the external media tools (`ffprobe`, `ffmpeg`, `vips`, `vipsheader`).
/// Injectable so tests can answer with fixtures.
abstract interface class ToolRunner {
  /// Whether [tool] can be started on this machine.
  Future<bool> isAvailable(String tool);

  /// Runs [tool] with [args] (no shell). Killed after [timeout]. Never throws
  /// for a tool that fails; a tool that cannot start gives exit code 127.
  Future<ToolResult> run(
    String tool,
    List<String> args, {
    required Duration timeout,
  });

  /// Kills every tool that is running.
  void cancelAll();
}

/// [ToolRunner] on real processes, started with `nice -n 19` when available.
class ProcessToolRunner implements ToolRunner {
  ProcessToolRunner({bool? lowPriority})
    : _nice = (lowPriority ?? true) ? _findNice() : null;

  final String? _nice;
  final Set<Process> _running = {};

  static String? _findNice() {
    if (Platform.isWindows) return null;
    for (final p in const ['/usr/bin/nice', '/bin/nice']) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  @override
  Future<bool> isAvailable(String tool) async {
    final flag = tool.startsWith('vips') ? '--version' : '-version';
    try {
      final r = await Process.run(tool, [
        flag,
      ]).timeout(const Duration(seconds: 10));
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<ToolResult> run(
    String tool,
    List<String> args, {
    required Duration timeout,
  }) async {
    final nice = _nice;
    final Process process;
    try {
      process = nice == null
          ? await Process.start(tool, args)
          : await Process.start(nice, ['-n', '19', tool, ...args]);
    } on ProcessException catch (e) {
      return ToolResult(127, '', e.message);
    }
    _running.add(process);
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
    });
    try {
      final out = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final code = await process.exitCode;
      return ToolResult(code, await out, await err, timedOut: timedOut);
    } finally {
      timer.cancel();
      _running.remove(process);
    }
  }

  @override
  void cancelAll() {
    for (final p in _running.toList()) {
      p.kill(ProcessSignal.sigkill);
    }
  }
}
