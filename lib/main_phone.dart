import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';

import 'phone/phone_controller.dart';
import 'phone/screens/connect_screen.dart';
import 'phone/screens/home_screen.dart';
import 'phone/screens/pin_screen.dart';
import 'phone/screens/scan_screen.dart';
import 'phone/secure_token_store.dart';

/// Phone app entry point (flavor `phone`, `com.codedbykay.tvsaver`).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureTokenStore();
  final controller = PhoneController(
    client: HubClient(tokenStore: store, clientName: 'Phone'),
    store: store,
  );
  runApp(PhoneApp(controller: controller));
}

class PhoneApp extends StatefulWidget {
  const PhoneApp({super.key, required this.controller, this.scannerBuilder});

  final PhoneController controller;

  /// Replaces the camera view (tests).
  final QrScannerBuilder? scannerBuilder;

  @override
  State<PhoneApp> createState() => _PhoneAppState();
}

class _PhoneAppState extends State<PhoneApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The multicast lock must not outlive the foreground.
    if (state == AppLifecycleState.resumed) {
      widget.controller.setForeground(true);
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      widget.controller.setForeground(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TV Saver',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => switch (widget.controller.screen) {
          PhoneScreen.loading => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
          PhoneScreen.connect => ConnectScreen(
            controller: widget.controller,
            scannerBuilder: widget.scannerBuilder,
          ),
          PhoneScreen.pin => PinScreen(controller: widget.controller),
          PhoneScreen.home => HomeScreen(controller: widget.controller),
        },
      ),
    );
  }
}
