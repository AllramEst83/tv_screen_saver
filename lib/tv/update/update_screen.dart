import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'updater.dart';

/// The TV's update screen (Menu key, then Down): the version that is
/// installed, the address of the update server on the PC, and what the check
/// found. OK checks, or installs when an update is ready. Up edits the
/// address (typed once; it is remembered). Nothing here changes a TV setting;
/// the system installer asks for the last word.
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key, required this.updater, required this.version});

  final TvUpdater updater;

  /// The installed version for the title line, such as `0.1.0 (3)`.
  final String version;

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _address = TextEditingController();
  final FocusNode _addressFocus = FocusNode();
  final FocusNode _keys = FocusNode();
  String? _addressError;

  TvUpdater get _updater => widget.updater;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  Future<void> _load() async {
    await _updater.loadSavedSource();
    if (!mounted) return;
    _address.text = _updater.sourceUrl.value ?? '';
    unawaited(_updater.checkNow());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _address.dispose();
    _addressFocus.dispose();
    _keys.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system installer: did it install?
    if (state == AppLifecycleState.resumed) {
      unawaited(_updater.installerClosed());
    }
  }

  Future<void> _submit(String text) async {
    try {
      await _updater.setSource(text);
      if (mounted) setState(() => _addressError = null);
    } on FormatException catch (e) {
      if (mounted) setState(() => _addressError = e.message);
    }
    if (mounted) _keys.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
      final s = _updater.state.value;
      if (s.canInstall) {
        unawaited(_updater.install());
      } else {
        unawaited(_updater.checkNow());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _addressFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _headline(UpdateState s) => switch (s.phase) {
    UpdatePhase.none => 'Press OK to look for an update',
    UpdatePhase.checking => 'Looking for an update…',
    UpdatePhase.upToDate => 'Up to date',
    UpdatePhase.available => 'Version ${s.versionName} is ready',
    UpdatePhase.downloading => 'Downloading version ${s.versionName}…',
    UpdatePhase.installing => 'Installing version ${s.versionName}…',
    UpdatePhase.needsPermission => 'One more step',
    UpdatePhase.error => 'The update did not work',
    UpdatePhase.checkFailed => 'No update found',
  };

  String _hint(UpdateState s) => s.canInstall
      ? 'OK: install   Up: change the address   Back: close'
      : 'OK: check again   Up: change the address   Back: close';

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final big = TextStyle(color: Colors.white, fontSize: height * 0.05);
    final normal = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.034,
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: EdgeInsets.all(height * 0.08),
          child: ValueListenableBuilder<UpdateState>(
            valueListenable: _updater.state,
            builder: (context, s, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Update', style: big),
                SizedBox(height: height * 0.01),
                Text('Installed: ${widget.version}', style: normal),
                SizedBox(height: height * 0.04),
                Text(
                  _headline(s),
                  key: const Key('update-headline'),
                  style: big.copyWith(fontSize: height * 0.045),
                ),
                if (s.message != null)
                  Padding(
                    padding: EdgeInsets.only(top: height * 0.01),
                    child: Text(
                      s.message!,
                      key: const Key('update-message'),
                      style: normal,
                    ),
                  ),
                if (s.phase == UpdatePhase.downloading)
                  Padding(
                    padding: EdgeInsets.only(top: height * 0.03),
                    child: LinearProgressIndicator(
                      key: const Key('update-progress'),
                      value: s.progress < 0 ? null : s.progress,
                      minHeight: height * 0.012,
                    ),
                  ),
                SizedBox(height: height * 0.05),
                Text('Update server on the PC', style: normal),
                SizedBox(height: height * 0.01),
                TextField(
                  key: const Key('update-address'),
                  controller: _address,
                  focusNode: _addressFocus,
                  style: normal.copyWith(color: Colors.white),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: _submit,
                  decoration: InputDecoration(
                    hintText: 'http://192.168.1.20:8099/update.json',
                    hintStyle: normal.copyWith(color: Colors.white38),
                    errorText: _addressError,
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white38),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white, width: 2),
                    ),
                  ),
                ),
                const Spacer(),
                Text(_hint(s), key: const Key('update-hint'), style: normal),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
