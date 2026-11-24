import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pi/pi_screen.dart';
import 'report_screen.dart';
import 'display_report.dart';
import 'video_spike/spike_screen.dart';

/// The Menu key's screen: the DisplayReport with the way into the earlier
/// spikes. OK opens the Pi stream and throughput screen (story 2-3), Right the
/// local video spike (story 1-2), Left (when [onPairPhone] is set) shows a
/// pairing code for another phone. Nothing here changes a TV setting.
class TvMenuScreen extends StatelessWidget {
  const TvMenuScreen({
    super.key,
    required this.version,
    this.panel,
    this.onPairPhone,
  });

  final String version;

  /// Native panel size from [DisplayReport.fetchPanelSize]; null falls back
  /// to `view.display.size` (marked "panel unverified").
  final PanelSize? panel;

  /// Called after the menu closes itself; null hides the Left key.
  final VoidCallback? onPairPhone;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final hint = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.035,
    );
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter) {
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const PiScreen()));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const SpikeScreen()));
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft && onPairPhone != null) {
          Navigator.of(context).pop();
          onPairPhone!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          ReportScreen(
            version: version,
            read: () => DisplayReport.read(panel: panel),
          ),
          Positioned(
            right: height * 0.1,
            bottom: height * 0.08,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('OK: Pi stream   Right: video spike', style: hint),
                if (onPairPhone != null)
                  Text('Left: pair another phone   Back: close', style: hint),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
