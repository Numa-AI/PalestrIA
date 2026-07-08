import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';

/// QR code disegnato via CustomPaint (pacchetto `barcode`, nessuna immagine di
/// rete). Riusabile da Tablet-QR e da "Invita clienti".
class QrView extends StatelessWidget {
  const QrView(this.data, {super.key, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _QrPainter(data),
      );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data);
  final String data;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final qr =
        Barcode.qrCode(errorCorrectLevel: BarcodeQRCorrectionLevel.medium);
    final module = Paint()..color = const Color(0xFF0F172A);
    for (final e in qr.make(data, width: size.width, height: size.height)) {
      if (e is BarcodeBar && e.black) {
        canvas.drawRect(
            Rect.fromLTWH(e.left, e.top, e.width, e.height), module);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
