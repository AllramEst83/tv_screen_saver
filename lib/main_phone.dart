import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:hub_core/hub_core.dart';

import 'phone/phone_controller.dart';
import 'phone/screens/connect_screen.dart';
import 'phone/screens/about_screen.dart' show VersionLoader;
import 'phone/screens/app_shell.dart';
import 'phone/screens/pin_screen.dart';
import 'phone/screens/scan_screen.dart';
import 'shared/secure_token_store.dart';

/// Phone app entry point (flavor `phone`, `com.codedbykay.tvsaver`).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureTokenStore();
  final controller = PhoneController(
    client: HubClient(tokenStore: store, clientName: await _deviceName()),
    store: store,
  );
  runApp(PhoneApp(controller: controller));
}

/// The phone's model (for example "Pixel 9 Pro XL"): the name a new phone
/// pairs with. The user can rename it in Settings.
Future<String> _deviceName() async {
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    final model = info.model.trim();
    if (model.isNotEmpty) return model;
  } catch (_) {}
  return 'Phone';
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Colors.indigo,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w500,
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {TargetPlatform.android: FadeForwardsPageTransitionsBuilder()},
    ),
    snackBarTheme: const SnackBarThemeData(showCloseIcon: false),
  );
}

class PhoneApp extends StatefulWidget {
  const PhoneApp({
    super.key,
    required this.controller,
    this.scannerBuilder,
    this.versionLoader,
  });

  final PhoneController controller;

  /// Replaces the camera view (tests).
  final QrScannerBuilder? scannerBuilder;

  /// Replaces the app version lookup (tests).
  final VersionLoader? versionLoader;

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
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
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
          PhoneScreen.home => AppShell(
            controller: widget.controller,
            versionLoader: widget.versionLoader,
          ),
        },
      ),
    );
  }
}
