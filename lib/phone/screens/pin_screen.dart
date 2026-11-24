import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hub_core/hub_core.dart';

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

  /// The `pinRetryInMs` whose countdown already started, so unrelated state
  /// changes that carry it along do not restart the countdown.
  int? _consumedMs;
  bool _lockoutEnded = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncLockout);
    _syncLockout();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncLockout);
    _timer?.cancel();
    _pin.dispose();
    super.dispose();
  }

  void _syncLockout() {
    final ms = widget.controller.hub.pinRetryInMs;
    if (ms == null) {
      _consumedMs = null;
      return;
    }
    if (ms == _consumedMs) return;
    _consumedMs = ms;
    _timer?.cancel();
    _lockoutEnded = false;
    _remaining = (ms / 1000).ceil();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _remaining--;
        if (_remaining <= 0) {
          t.cancel();
          _lockoutEnded = true;
        }
      });
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hub = widget.controller.hub;
    final locked = _remaining > 0;
    final error = locked
        ? 'Too many tries. Wait $_remaining s.'
        : (_lockoutEnded && hub.pinRetryInMs != null
              ? 'You can try again now.'
              : (hub.pinRetryInMs != null ? null : hub.lastError));
    return Scaffold(
      appBar: AppBar(title: const Text('Enter the PIN')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Enter the $kPinLength-digit PIN shown on the TV.',
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
                maxLength: kPinLength,
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
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('pin-submit'),
                onPressed: !locked && _pin.text.length == kPinLength
                    ? _submit
                    : null,
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
    if (_remaining > 0 || _pin.text.length != kPinLength) return;
    widget.controller.submitPin(_pin.text);
    _pin.clear();
    setState(() => _lockoutEnded = false);
  }
}
