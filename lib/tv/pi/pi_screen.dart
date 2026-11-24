import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../video_spike/spike_native.dart';
import 'pi_config.dart';
import 'pi_player.dart';
import 'throughput_runner.dart';

void _defaultLog(String line) => debugPrint(line);

/// Remote-driven Pi stream & 1 GiB throughput benchmark screen (story 2-3).
class PiScreen extends StatefulWidget {
  const PiScreen({
    super.key,
    this.native = const ChannelPiVideoNative(),
    this.configLoader = loadPiConfig,
    this.throughputRunner,
    this.healthCheck = defaultHealthCheck,
    this.media3View,
    this.log = _defaultLog,
  });

  final PiVideoNative native;
  final Future<PiConfig> Function(String filesDir) configLoader;
  final ThroughputRunner? throughputRunner;
  final Future<bool> Function(Uri healthUri) healthCheck;
  final Widget Function(void Function(int id) onCreated)? media3View;
  final void Function(String line) log;

  @override
  State<PiScreen> createState() => _PiScreenState();
}

class _PiScreenState extends State<PiScreen> {
  late final ThroughputRunner _runner =
      widget.throughputRunner ?? ThroughputRunner();

  PiConfig? _config;
  String? _configError;
  bool _loading = true;
  int _selected = 0;
  bool _playing = false;

  bool _runningThroughput = false;
  ThroughputProgress? _progress;
  ThroughputResult? _result;
  String? _throughputError;
  String? _throughputNotice;

  static const _rowCount = 2;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_runningThroughput) {
      _runner.cancel();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final dir = await widget.native.filesDir();
    if (!mounted) return;
    if (dir == null) {
      setState(() {
        _loading = false;
        _configError = 'App files directory unavailable';
      });
      return;
    }
    try {
      final cfg = await widget.configLoader(dir);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _config = cfg;
      });
    } on PiConfigException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _configError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _configError = 'Failed to load pi_config.json: $e';
      });
    }
  }

  void _activate() {
    final cfg = _config;
    if (cfg == null) return;
    if (_selected == 0) {
      if (_runningThroughput) _runner.cancel();
      setState(() => _playing = true);
    } else if (_selected == 1 && !_runningThroughput) {
      unawaited(_runThroughput(cfg));
    }
  }

  Future<void> _runThroughput(PiConfig cfg) async {
    setState(() {
      _runningThroughput = true;
      _progress = null;
      _result = null;
      _throughputError = null;
      _throughputNotice = null;
    });
    try {
      final result = await _runner.run(
        cfg,
        onProgress: (p) {
          if (mounted && _runningThroughput) {
            setState(() => _progress = p);
          }
        },
      );
      if (!mounted) return;
      widget.log(piThroughputLogLine(result));
      setState(() {
        _runningThroughput = false;
        _result = result;
      });
    } on ThroughputCancelledException {
      if (!mounted) return;
      setState(() {
        _runningThroughput = false;
        _progress = null;
        _throughputNotice = 'Throughput test cancelled';
      });
    } on ThroughputException catch (e) {
      if (!mounted) return;
      setState(() {
        _runningThroughput = false;
        _progress = null;
        _throughputError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runningThroughput = false;
        _progress = null;
        _throughputError = e.toString();
      });
    }
  }

  void _cancelThroughput() {
    if (!_runningThroughput) return;
    _runner.cancel();
    setState(() {
      _runningThroughput = false;
      _progress = null;
      _throughputNotice = 'Throughput test cancelled';
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_runningThroughput &&
        (key == LogicalKeyboardKey.escape ||
            key == LogicalKeyboardKey.goBack ||
            key == LogicalKeyboardKey.browserBack)) {
      _cancelThroughput();
      return KeyEventResult.handled;
    }
    if (_config == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1).clamp(0, _rowCount - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1).clamp(0, _rowCount - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.arrowRight) {
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    if (_playing && cfg != null) {
      return PiPlayer(
        config: cfg,
        native: widget.native,
        log: widget.log,
        healthCheck: widget.healthCheck,
        media3View: widget.media3View,
        onExit: () {
          if (mounted) setState(() => _playing = false);
        },
      );
    }

    return PopScope(
      canPop: !_runningThroughput,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _runningThroughput) _cancelThroughput();
      },
      child: Focus(autofocus: true, onKeyEvent: _onKey, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final title = TextStyle(
      color: Colors.white,
      fontSize: height * 0.07,
      fontWeight: FontWeight.w600,
    );
    final body = TextStyle(color: Colors.white, fontSize: height * 0.045);
    final note = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.034,
    );

    final cfg = _config;
    return ColoredBox(
      color: Colors.black,
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: height * 0.1,
          vertical: height * 0.08,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pi stream & throughput', style: title),
            SizedBox(height: height * 0.02),
            if (_loading)
              Text('Loading Pi config…', style: body)
            else if (_configError != null || cfg == null) ...[
              Text(
                _configError ?? 'Missing pi_config.json',
                style: body.copyWith(color: const Color(0xFFFF8A80)),
              ),
              SizedBox(height: height * 0.03),
              Text('Push pi_config.json from the PC (Git Bash):', style: note),
              SizedBox(height: height * 0.01),
              Text(setupPhase2Hint, style: note),
            ] else ...[
              Text(
                'Pi ${cfg.host}:${cfg.port}   |   '
                'Up/Down: move   OK: select   Back: ${_runningThroughput ? 'cancel' : 'leave'}',
                style: note,
              ),
              SizedBox(height: height * 0.03),
              _row(
                0,
                'Play Pi playlist (${cfg.playlist.length} clips)',
                _selected == 0,
                body,
              ),
              _row(
                1,
                _runningThroughput
                    ? 'Running 1 GiB throughput test…'
                    : 'Run 1 GiB throughput test (${cfg.throughputFile})',
                _selected == 1,
                body,
              ),
              SizedBox(height: height * 0.03),
              Text('Playlist: ${cfg.playlist.join(', ')}', style: note),
              SizedBox(height: height * 0.03),
              ..._throughputStatus(body, note),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _throughputStatus(TextStyle body, TextStyle note) {
    if (_runningThroughput) {
      final p = _progress;
      if (p == null) {
        return [Text('Connecting to Pi for throughput test…', style: body)];
      }
      final gotMiB = (p.bytes / (1024 * 1024)).toStringAsFixed(1);
      final totalMiB = p.expectedBytes > 0
          ? ' / ${(p.expectedBytes / (1024 * 1024)).toStringAsFixed(1)} MiB'
          : ' MiB';
      return [
        Text(
          'Downloaded $gotMiB$totalMiB   '
          '(${p.mbPerSec.toStringAsFixed(1)} MB/s, ${p.mbps.toStringAsFixed(1)} Mbps)',
          style: body,
        ),
        Text('In-memory only (0 flash writes). Press Back to cancel.', style: note),
      ];
    }
    if (_result != null) {
      final r = _result!;
      return [
        Text(
          'Measured: ${r.mbps.toStringAsFixed(2)} Mbps   |   '
          '60% ceiling: ${r.ceilingMbps.toStringAsFixed(2)} Mbps',
          style: body,
        ),
        Text(
          '${r.bytes} bytes in ${r.seconds.toStringAsFixed(2)} s (0 flash writes)',
          style: note,
        ),
      ];
    }
    if (_throughputError != null) {
      return [
        Text(
          'Throughput error: $_throughputError',
          style: body.copyWith(color: const Color(0xFFFF8A80)),
        ),
        if (_throughputError!.contains('401'))
          Text('Re-run: $setupPhase2Hint', style: note),
      ];
    }
    if (_throughputNotice != null) {
      return [Text(_throughputNotice!, style: note)];
    }
    return const [];
  }

  Widget _row(int index, String text, bool selected, TextStyle style) =>
      Container(
        key: ValueKey('pi-row-$index'),
        color: selected ? const Color(0xFF2A4D8F) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(text, style: style),
      );
}
