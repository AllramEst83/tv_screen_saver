import 'package:flutter/material.dart';

import '../phone_controller.dart';
import 'scan_screen.dart';

/// Shown when the phone is not connected: status per connection phase,
/// "Scan QR" and, for a saved pairing, "Retry".
class ConnectScreen extends StatelessWidget {
  const ConnectScreen({
    super.key,
    required this.controller,
    this.scannerBuilder,
  });

  final PhoneController controller;

  /// Replaces the camera view (tests).
  final QrScannerBuilder? scannerBuilder;

  @override
  Widget build(BuildContext context) {
    final text = controller.statusText;
    return Scaffold(
      appBar: AppBar(title: const Text('TV Saver')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                const Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Icon(Icons.tv, size: 64),
                ),
              Text(
                text,
                key: const Key('connect-status'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                key: const Key('scan-qr'),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ScanScreen(
                      controller: controller,
                      scannerBuilder: scannerBuilder,
                    ),
                  ),
                ),
              ),
              if (controller.canRetry) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('retry'),
                  onPressed: controller.retry,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
