import 'package:barcode/barcode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Vista "Tablet — QR" (port di renderTabletQR, §8.8): mostra un QR che apre
/// la scheda dell'utente sul tablet della palestra
/// (`<webBaseUrl>/tablet.html?uid=<id>`). Resta valido anche cambiando scheda.
class TabletQrView extends ConsumerWidget {
  const TabletQrView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(sessionProvider)?.user.id;
    final name = ref.watch(userProfileProvider).value?.name;
    if (uid == null) {
      return const Scaffold(
        backgroundColor: AppColors.slateBg,
        body: Center(
            child: Text('Devi essere loggato.', style: AppText.meta)),
      );
    }
    final url = '${AppConfig.webBaseUrl}/tablet.html?uid=$uid';

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.xxxl, AppSpacing.lg, 120),
          child: AppCard(
            padding: const EdgeInsets.all(AppSpacing.xl),
            radius: 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Il tuo QR per il Tablet',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy)),
                const SizedBox(height: AppSpacing.lg),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: CustomPaint(
                    size: const Size(220, 220),
                    painter: _QrPainter(url),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if ((name ?? '').isNotEmpty)
                  Text(name!,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: url));
                    if (context.mounted) {
                      AppSnack.success(context, 'Link copiato!');
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copia link'),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                    'Scansiona dal tablet in palestra. Resta valido anche se '
                    'cambi scheda.',
                    textAlign: TextAlign.center,
                    style: AppText.meta),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data);
  final String data;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = Colors.white);
    final qr = Barcode.qrCode(
        errorCorrectLevel: BarcodeQRCorrectionLevel.medium);
    final module = Paint()..color = AppColors.navy;
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
