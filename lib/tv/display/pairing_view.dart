import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import 'display_client.dart';

/// The pairing screen: a QR code the phone scans and the PIN as the fallback.
class PairingView extends StatelessWidget {
  const PairingView({
    super.key,
    required this.pairing,
    this.error,
    this.hint = 'Scan with the TV Saver app on your phone',
  });

  /// The latest code from the Pi; null while the Pi has not sent one yet.
  final PairingInfo? pairing;
  final String? error;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final info = pairing;
    final title = TextStyle(
      color: Colors.white,
      fontSize: height * 0.06,
      fontWeight: FontWeight.w600,
    );
    final note = TextStyle(
      color: const Color(0xFFD0D0D0),
      fontSize: height * 0.034,
    );
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: info == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Pair a phone', style: title),
                  SizedBox(height: height * 0.03),
                  Text(
                    error ?? 'Getting a pairing code from the Pi…',
                    key: const Key('pairing-status'),
                    style: error == null
                        ? note
                        : note.copyWith(color: const Color(0xFFFF8A80)),
                  ),
                ],
              )
            : FittedBox(
                // Never overflow a small or odd-shaped window.
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    QrCodeView(
                      key: const Key('pairing-qr'),
                      data: info.qr,
                      size: height * 0.62,
                    ),
                    SizedBox(width: height * 0.08),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Pair a phone', style: title),
                        SizedBox(height: height * 0.03),
                        Text(hint, style: note),
                        SizedBox(height: height * 0.05),
                        Text('Or type this PIN', style: note),
                        Text(
                          info.pin,
                          key: const Key('pairing-pin'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: height * 0.14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: height * 0.02,
                          ),
                        ),
                        SizedBox(height: height * 0.03),
                        Text('The code refreshes by itself.', style: note),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// A QR code drawn black on white with a quiet zone.
class QrCodeView extends StatelessWidget {
  const QrCodeView({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    return CustomPaint(size: Size.square(size), painter: _QrPainter(image));
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  static const _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final cell = size.width / (n + 2 * _quiet);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final dark = Paint()..color = Colors.black;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (image.isDark(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(
              (c + _quiet) * cell,
              (r + _quiet) * cell,
              cell + 0.5,
              cell + 0.5,
            ),
            dark,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
