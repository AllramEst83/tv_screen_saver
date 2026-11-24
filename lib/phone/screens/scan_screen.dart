import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../multicast_lock.dart';
import '../phone_controller.dart';

/// Why the camera view cannot scan.
enum CameraProblem { denied, other }

/// Builds the camera view. Call [onCode] with each decoded string and
/// [onProblem] when the camera cannot start.
typedef QrScannerBuilder = Widget Function(
  BuildContext context,
  ValueChanged<String> onCode,
  ValueChanged<CameraProblem> onProblem,
);

/// A frame can hold several codes: prefer one that is a pairing URI, else the
/// first readable one (which the caller then reports as not a TV Saver code).
String? pickScannedCode(Iterable<String?> raws) {
  final codes = [for (final r in raws) ?r];
  if (codes.isEmpty) return null;
  return codes.firstWhere(
    (r) => PairQrData.tryParse(r) != null,
    orElse: () => codes.first,
  );
}

Widget _cameraScanner(
  BuildContext context,
  ValueChanged<String> onCode,
  ValueChanged<CameraProblem> onProblem,
) => MobileScanner(
  onDetect: (capture) {
    final raw = pickScannedCode([for (final b in capture.barcodes) b.rawValue]);
    if (raw != null) onCode(raw);
  },
  errorBuilder: (context, error) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onProblem(
        error.errorCode == MobileScannerErrorCode.permissionDenied
            ? CameraProblem.denied
            : CameraProblem.other,
      );
    });
    return const ColoredBox(color: Colors.black);
  },
);

/// One-shot QR scanner. Leaves as soon as a TV Saver code was accepted.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.controller, this.scannerBuilder});

  final PhoneController controller;
  final QrScannerBuilder? scannerBuilder;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> with WidgetsBindingObserver {
  CameraProblem? _problem;
  String? _error;
  Timer? _errorTimer;
  bool _busy = false;
  bool _popped = false;
  int _scannerGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.setScanning(true);
    widget.controller.addListener(_onController);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    _errorTimer?.cancel();
    widget.controller.setScanning(false);
    super.dispose();
  }

  /// Back from the system settings: if the camera was denied, try again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _problem == CameraProblem.denied) {
      setState(() {
        _problem = null;
        _scannerGeneration++; // A new scanner view restarts the camera.
      });
    }
  }

  /// Never cover Home or the PIN screen.
  void _onController() {
    if (widget.controller.screen != PhoneScreen.connect) _leave();
  }

  void _leave() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  Future<void> _onCode(String raw) async {
    if (_busy || _popped) return;
    _busy = true;
    _errorTimer?.cancel();
    if (_error != null) setState(() => _error = null);
    final outcome = await widget.controller.pairFromQr(raw);
    if (!mounted) return;
    if (outcome == QrOutcome.invalid) {
      setState(() => _error = HubMessages.invalidQr);
      // Let the user move the camera before the next code counts.
      _errorTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _error = null);
        _busy = false;
      });
      return;
    }
    _leave();
  }

  void _onProblem(CameraProblem problem) {
    if (!mounted || _problem == problem) return;
    setState(() => _problem = problem);
  }

  @override
  Widget build(BuildContext context) {
    final builder = widget.scannerBuilder ?? _cameraScanner;
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the TV code')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          KeyedSubtree(
            key: ValueKey(_scannerGeneration),
            child: builder(context, _onCode, _onProblem),
          ),
          if (problem != null)
            Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    problem == CameraProblem.denied
                        ? 'TV Saver needs the camera to scan the QR code. '
                              'Allow camera access in the app settings.'
                        : 'The camera could not be started.',
                    key: const Key('camera-problem'),
                    textAlign: TextAlign.center,
                  ),
                  if (problem == CameraProblem.denied) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('open-settings'),
                      onPressed: openAppSettings,
                      child: const Text('Open settings'),
                    ),
                  ],
                ],
              ),
            ),
          if (_error != null && problem == null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, key: const Key('scan-error')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
