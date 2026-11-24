import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../multicast_lock.dart';
import '../phone_controller.dart';

/// Why the camera view cannot scan.
enum CameraProblem { denied, other }

/// Builds the camera view. Call [onCode] with each decoded string and
/// [onProblem] when the camera cannot start.
typedef QrScannerBuilder =
    Widget Function(
      BuildContext context,
      ValueChanged<String> onCode,
      ValueChanged<CameraProblem> onProblem,
    );

Widget _cameraScanner(
  BuildContext context,
  ValueChanged<String> onCode,
  ValueChanged<CameraProblem> onProblem,
) => MobileScanner(
  onDetect: (capture) {
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw != null) {
        onCode(raw);
        return;
      }
    }
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

class _ScanScreenState extends State<ScanScreen> {
  CameraProblem? _problem;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.setScanning(true);
  }

  @override
  void dispose() {
    widget.controller.setScanning(false);
    super.dispose();
  }

  Future<void> _onCode(String raw) async {
    if (_busy) return;
    _busy = true;
    final outcome = await widget.controller.pairFromQr(raw);
    if (!mounted) return;
    if (outcome == QrOutcome.invalid) {
      setState(() => _error = HubMessages.invalidQr);
      // Let the user move the camera before the next code counts.
      await Future<void>.delayed(const Duration(seconds: 2));
      _busy = false;
      return;
    }
    Navigator.of(context).pop();
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
          builder(context, _onCode, _onProblem),
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
