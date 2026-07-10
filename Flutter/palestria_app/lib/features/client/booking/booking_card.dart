import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';

import '../../../core/data/booking_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import 'booking_providers.dart';

/// Card di una prenotazione del cliente (port di prenotazioni.html §7.4):
/// data/ora/tipo, badge pagamento e regole di annullo. Riusata nelle tab
/// Prossime/Passate del Profilo.
class BookingCard extends ConsumerWidget {
  const BookingCard({
    super.key,
    required this.booking,
    required this.config,
    required this.showCancel,
  });

  final Booking booking;
  final OrgScheduleConfig config;

  /// true nella tab "Prossime": mostra l'azione di annullo/richiesta.
  final bool showCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = booking;
    final color = config.slotColor(b.slotType);
    final day = parseYmd(b.date);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 5)),
        boxShadow: AppShadows.card,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_outlined,
                      size: 15,
                      color: AppColors.navy,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        longDateOf(day),
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      Icons.schedule,
                      size: 14,
                      color: AppColors.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      b.time,
                      style: const TextStyle(
                        fontSize: 13.5,
                        color: AppColors.muted,
                        fontFeatures: AppText.tabularNums,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  config.slotName(b.slotType),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.subtle,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _paymentBadge(b),
              const SizedBox(height: 8),
              if (showCancel) _cancelAction(context, ref, b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _paymentBadge(Booking b) {
    String text;
    Color bg;
    Color fg;
    if (b.status == 'cancelled') {
      text = '✕ Annullata';
      bg = AppColors.cancelledBg;
      fg = AppColors.cancelledText;
    } else if (b.isBillingVoided) {
      text = 'Saldo annullato · cambio modello';
      bg = AppColors.cancelledBg;
      fg = AppColors.cancelledText;
    } else if (b.paid) {
      text = switch (b.paymentMethod) {
        'contanti' => '💵 Pagata con Contanti',
        'contanti-report' => '🧾 Pagata con Contanti (Report)',
        'carta' => '💳 Pagata con Carta',
        'iban' => '🏦 Pagata con Bonifico',
        'stripe' => '💳 Pagata con Stripe',
        'pacchetto' => '🎫 Pagata con Pacchetto',
        'abbonamento' => '📅 Pagata con Abbonamento',
        'gratuito' => '🎁 Lezione Gratuita',
        _ => '✓ Pagata',
      };
      bg = AppColors.paidBg;
      fg = AppColors.paidText;
    } else {
      text = 'Da pagare';
      bg = AppColors.unpaidBg;
      fg = AppColors.unpaidText;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }

  /// Regole di annullo (§7.4): grace 10 min → sempre; group-class > 3 gg o
  /// altri tipi > 24 h → diretto; 2–24 h (non group-class) → richiesta;
  /// altrimenti bloccato.
  Widget _cancelAction(BuildContext context, WidgetRef ref, Booking b) {
    if (b.status == 'cancelled') return const SizedBox.shrink();
    if (b.status == 'cancellation_requested') {
      return _chip(
        '⏳ Annullamento in attesa',
        AppColors.cancelReqBg,
        AppColors.cancelReqText,
      );
    }

    final now = DateTime.now();
    final msToLesson = lessonStart(b.date, b.time).difference(now);
    if (msToLesson.isNegative) return const SizedBox.shrink();

    final inGrace =
        b.createdAt != null &&
        now.difference(b.createdAt!) <= const Duration(minutes: 10);
    final isGroupClass = b.slotType == 'group-class';
    final direct =
        inGrace ||
        (isGroupClass && msToLesson > const Duration(days: 3)) ||
        (!isGroupClass && msToLesson > const Duration(hours: 24));
    final canRequest =
        !isGroupClass &&
        msToLesson > const Duration(hours: 2) &&
        msToLesson <= const Duration(hours: 24);

    if (direct) {
      return _ghostButton(
        'Annulla prenotazione',
        () => _cancelDirect(context, ref, b),
      );
    }
    if (canRequest) {
      return _ghostButton(
        'Richiedi annullamento',
        () => _requestCancel(context, ref, b),
      );
    }
    final reason = msToLesson <= const Duration(hours: 2)
        ? 'meno di 2 ore'
        : 'slot prenotato entro 3 giorni';
    return _chip(
      '🔒 Non annullabile ($reason)',
      AppColors.cancelledBg,
      AppColors.cancelledText,
    );
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg),
    ),
  );

  Widget _ghostButton(String text, VoidCallback onTap) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      foregroundColor: AppColors.dangerDark,
      side: const BorderSide(color: AppColors.borderGray),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      minimumSize: const Size(0, 30),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    ),
    child: Text(text),
  );

  Future<void> _cancelDirect(
    BuildContext context,
    WidgetRef ref,
    Booking b,
  ) async {
    final message = b.slotType == 'group-class'
        ? 'Confermare l\'annullamento?\n\nLa prenotazione sarà annullata e lo slot diventerà una Lezione di Gruppo aperta al pubblico.'
        : 'Confermare l\'annullamento della prenotazione?';
    final confirmLabel = b.slotType == 'group-class'
        ? 'Annulla prenotazione'
        : 'Conferma';
    final ok = await _confirmDialog(
      context,
      message,
      confirmLabel,
      cancelLabel: b.slotType == 'group-class' ? 'Indietro' : 'Annulla',
    );
    if (ok != true || b.sbId == null) return;

    final repo = await ref.read(bookingRepositoryProvider.future);
    final result = await repo.cancelBooking(b.sbId!);
    if (!context.mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Errore di rete. Riprova.')),
      );
      return;
    }
    ref.invalidate(ownBookingsProvider);
    ref.invalidate(availabilityProvider);
    final client = ref.read(supabaseProvider);
    final capacity = config.slotTypes[b.slotType]?.defaultCapacity;
    final body = {
      'booking_id': b.sbId,
      'name': b.name ?? '',
      'date_display': b.dateDisplay ?? b.date,
      'date': b.date,
      'time': b.time,
      'slot_type': b.slotType,
      'max_capacity': capacity,
    };
    try {
      await client.functions.invoke('notify-admin-cancellation', body: body);
      await client.functions.invoke(
        'notify-slot-available',
        body: {
          'date_display': b.dateDisplay ?? b.date,
          'date': b.date,
          'time': b.time,
          'exclude_user_id': ref.read(sessionProvider)?.user.id,
          'max_capacity': capacity,
        },
      );
    } catch (_) {
      // L'annullamento è già salvato: le notifiche restano best-effort.
    }
  }

  Future<void> _requestCancel(
    BuildContext context,
    WidgetRef ref,
    Booking b,
  ) async {
    final ok = await _confirmDialog(
      context,
      'Richiedere l\'annullamento?\n\n• Se qualcuno prenota al tuo posto, la prenotazione sarà annullata.\n• Se entro 2 ore dalla lezione nessuno ha preso il tuo posto, l\'annullamento viene negato e dovrai presentarti.',
      'Richiedi annullamento',
    );
    if (ok != true || b.sbId == null) return;

    final repo = await ref.read(bookingRepositoryProvider.future);
    final result = await repo.requestCancellation(b.sbId!);
    if (!context.mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Errore di rete. Riprova.')),
      );
      return;
    }
    ref.invalidate(ownBookingsProvider);
  }

  Future<bool?> _confirmDialog(
    BuildContext context,
    String message,
    String confirmLabel, {
    String cancelLabel = 'Annulla',
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }
}
