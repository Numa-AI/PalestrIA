import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config.dart';
import '../../../core/data/booking_repository.dart';
import '../../../core/theme/tokens.dart';
import '../../shared/qr_view.dart';

/// Sheet "Invita clienti": mostra il link d'invito allo studio (con il codice
/// palestra già incluso) + QR, da condividere su WhatsApp o copiare. Il link
/// apre la registrazione cliente precompilata: oggi la PWA
/// (`login.html?org=<slug>`), e l'app nativa quando gli App Link https saranno
/// attivi sul dominio. Parità con la funzione web (CLAUDE.md §0.3).
Future<void> showInviteClientsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _InviteSheet(),
  );
}

class _InviteSheet extends ConsumerWidget {
  const _InviteSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slugAsync = ref.watch(orgSlugProvider);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.md,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: slugAsync.when(
          loading: () => const SizedBox(
            height: 240,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => SizedBox(
            height: 160,
            child: Center(child: Text('Errore: $e', style: AppText.meta)),
          ),
          data: (slug) => _content(context, slug),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, String slug) {
    if (slug.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text('Studio non identificato.', style: AppText.meta),
        ),
      );
    }
    final link = '${AppConfig.webBaseUrl}/login.html?org=$slug';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Invita i tuoi clienti', style: AppText.sectionTitle),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Condividi questo link: i clienti si iscrivono al tuo studio con il '
          'codice palestra già inserito.',
          style: AppText.meta,
        ),
        const SizedBox(height: AppSpacing.lg),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: QrView(link, size: 200),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.slateBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  link,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.slate800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Codice: $slug',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copiato!')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copia'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.whatsapp,
                ),
                onPressed: () async {
                  final text = 'Iscriviti al mio studio su PalestrIA: $link';
                  final wa = Uri.parse(
                    'https://wa.me/?text=${Uri.encodeComponent(text)}',
                  );
                  await launchUrl(wa, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.share, size: 18),
                label: const Text('WhatsApp'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }
}
