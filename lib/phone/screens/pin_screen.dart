import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../phone_controller.dart';

/// PIN entry, shown when the Pi asks for it (QR code reused or expired).
/// After 3 wrong tries the Pi locks pairing for a while: a countdown shows
/// how long.
class PinScreen extends StatefulWidget {
  const PinScreen({super.key, required this.controller});

  final PhoneController controller;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final _pin = TextEditingController();
  Timer? _timer;
  int _remaining = 0;
  int? _seenRetryMs;
  Object? _seenState;

  @override
  void dispose() {
    _timer?.cancel();
    _pin.dispose();
    super.dispose();
  }

  void _syncLockout() {
    final hub = widget.controller.hub;
    if (identical(_seenState, hub)) return;
    _seenState = hub;
    final ms = hub.pinRetryInMs;
    if (ms == null) {
      _seenRetryMs = null;
      _remaining = 0;
      _timer?.cancel();
      return;
    }
    if (ms == _seenRetryMs && _remaining > 0) return;
    _seenRetryMs = ms;
    _remaining = (ms / 1000).ceil();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    _syncLockout();
    final hub = widget.controller.hub;
    final locked = _remaining > 0;
    final error = locked
        ? 'Too many tries. Wait $_remaining s.'
        : (hub.pinRetryInMs != null ? null : hub.lastError);
    return Scaffold(
      appBar: AppBar(title: const Text('Enter the PIN')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter the 4-digit PIN shown on the TV.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('pin-field'),
                controller: _pin,
                enabled: !locked,
                autofocus: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                maxLength: 4,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: Theme.of(context).textTheme.headlineMedium,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    error,
                    key: const Key('pin-error'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('pin-submit'),
                onPressed: !locked && _pin.text.length == 4 ? _submit : null,
                child: const Text('Pair'),
              ),
              TextButton(
                key: const Key('pin-cancel'),
                onPressed: widget.controller.cancelPin,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (_remaining > 0 || _pin.text.length != 4) return;
    widget.controller.submitPin(_pin.text);
    _pin.clear();
    setState(() {});
  }
}
