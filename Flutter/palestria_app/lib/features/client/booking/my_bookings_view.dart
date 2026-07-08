import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/booking_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import 'booking_providers.dart';

/// "Le mie prenotazioni" (port di prenotazioni.html §7.4): tab
/// Prossime/Passate, paginazione 5 → +20, card con badge e regole di annullo.
class MyBookingsView extends ConsumerStatefulWidget {
  const MyBookingsView({super.key});

  @override
  ConsumerState<MyBookingsView> createState() => _MyBookingsViewState();
}

class _MyBookingsViewState extends ConsumerState<MyBookingsView> {
  bool _showUpcoming = true;
  int _visible = 5;

  @override
  Widget build(BuildContext context) {
    final bookingsAsync = ref.watch(ownBookingsProvider);
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    final primary = Theme.of(context).colorScheme.primary;

    return bookingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Errore di caricamento: $e')),
      data: (all) {
        final now = DateTime.now();
        final upcoming = all
            .where((b) => lessonStart(b.date, b.time).isAfter(now))
            .toList()
          ..sort((a, b) => lessonStart(a.date, a.time)
              .compareTo(lessonStart(b.date, b.time)));
        final past = all
            .where((b) => !lessonStart(b.date, b.time).isAfter(now))
            .toList()
          ..sort((a, b) => lessonStart(b.date, b.time)
              .compareTo(lessonStart(a.date, a.time)));

        final list = _showUpcoming ? upcoming : past;
        final visible = list.take(_visible).toList();
        final remaining = list.length - visible.length;

        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(ownBookingsProvider),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              _tabs(primary),
              const SizedBox(height: AppSpacing.md),
              if (visible.isEmpty)
                Container(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      _showUpcoming
                          ? 'Nessuna prenotazione futura.'
                          : 'Nessuna prenotazione passata.',
                      style: AppText.meta,
                    ),
                  ),
                )
              else ...[
                for (final b in visible) _bookingCard(b, config),
                if (remaining > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: OutlinedButton(
                      onPressed: () => setState(() => _visible += 20),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: primary,
                        side: const BorderSide(
                            color: Color(0xFFE5E7EB), width: 1.5),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text('Mostra altro ($remaining)'),
                    ),
                  ),
              ],
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        );
      },
    );
  }

  Widget _tabs(Color primary) {
    Widget tab(String label, bool active, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: active ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
                boxShadow: active
                    ? [
                        BoxShadow(
                            color: primary.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3)),
                      ]
                    : null,
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : AppColors.muted,
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab('Prossime', _showUpcoming, () => setState(() {
                _showUpcoming = true;
                _visible = 5;
              })),
          tab('Passate', !_showUpcoming, () => setState(() {
                _showUpcoming = false;
                _visible = 5;
              })),
        ],
      ),
    );
  }

  Widget _bookingCard(Booking b, OrgScheduleConfig config) {
    final color = config.slotColor(b.slotType);
    final day = parseYmd(b.date);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
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
                    const Icon(Icons.calendar_today_outlined,
                        size: 15, color: AppColors.navy),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(longDateOf(day),
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.schedule,
                        size: 14, color: Color(0xFF666666)),
                    const SizedBox(width: 6),
                    Text(b.time,
                        style: const TextStyle(
                            fontSize: 13.5,
                            color: Color(0xFF666666),
                            fontFeatures: AppText.tabularNums)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(config.slotName(b.slotType),
                    style: const TextStyle(
                        fontSize: 12.5, color: Color(0xFF999999))),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _paymentBadge(b),
              const SizedBox(height: 8),
              if (_showUpcoming) _cancelAction(b),
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
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  /// Regole di annullo (§7.4): grace 10 min → sempre; group-class > 3 gg o
  /// altri tipi > 24 h → diretto; 2–24 h (non group-class) → richiesta;
  /// altrimenti bloccato.
  Widget _cancelAction(Booking b) {
    if (b.status == 'cancelled') return const SizedBox.shrink();
    if (b.status == 'cancellation_requested') {
      return _chip('⏳ Annullamento in attesa', const Color(0xFFFEF3C7),
          const Color(0xFF92400E));
    }

    final now = DateTime.now();
    final msToLesson =
        lessonStart(b.date, b.time).difference(now);
    if (msToLesson.isNegative) return const SizedBox.shrink();

    final inGrace = b.createdAt != null &&
        now.difference(b.createdAt!) <= const Duration(minutes: 10);
    final isGroupClass = b.slotType == 'group-class';
    final direct = inGrace ||
        (isGroupClass && msToLesson > const Duration(days: 3)) ||
        (!isGroupClass && msToLesson > const Duration(hours: 24));
    final canRequest = !isGroupClass &&
        msToLesson > const Duration(hours: 2) &&
        msToLesson <= const Duration(hours: 24);

    if (direct) {
      return _ghostButton('Annulla prenotazione', () => _cancelDirect(b));
    }
    if (canRequest) {
      return _ghostButton('Richiedi annullamento', () => _requestCancel(b));
    }
    final reason = msToLesson <= const Duration(hours: 2)
        ? 'meno di 2 ore'
        : 'slot prenotato entro 3 giorni';
    return _chip('🔒 Non annullabile ($reason)', const Color(0xFFF3F4F6),
        const Color(0xFF6B7280));
  }

  Widget _chip(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text,
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: fg)),
      );

  Widget _ghostButton(String text, VoidCallback onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFDC2626),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: const Size(0, 30),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          textStyle:
              const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
        child: Text(text),
      );

  Future<void> _cancelDirect(Booking b) async {
    final message = b.slotType == 'group-class'
        ? 'Confermare l\'annullamento?\n\nLa prenotazione sarà annullata e lo slot diventerà una Lezione di Gruppo aperta al pubblico.'
        : 'Confermare l\'annullamento della prenotazione?';
    final confirmLabel = b.slotType == 'group-class'
        ? 'Annulla prenotazione'
        : 'Conferma';
    final ok = await _confirmDialog(message, confirmLabel,
        cancelLabel: b.slotType == 'group-class' ? 'Indietro' : 'Annulla');
    if (ok != true || b.sbId == null) return;

    final repo = await ref.read(bookingRepositoryProvider.future);
    final result = await repo.cancelBooking(b.sbId!);
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.error ?? 'Errore di rete. Riprova.')));
      return;
    }
    ref.invalidate(ownBookingsProvider);
    ref.invalidate(availabilityProvider);
  }

  Future<void> _requestCancel(Booking b) async {
    final ok = await _confirmDialog(
      'Richiedere l\'annullamento?\n\n• Se qualcuno prenota al tuo posto, la prenotazione sarà annullata.\n• Se entro 2 ore dalla lezione nessuno ha preso il tuo posto, l\'annullamento viene negato e dovrai presentarti.',
      'Richiedi annullamento',
    );
    if (ok != true || b.sbId == null) return;

    final repo = await ref.read(bookingRepositoryProvider.future);
    final result = await repo.requestCancellation(b.sbId!);
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.error ?? 'Errore di rete. Riprova.')));
      return;
    }
    ref.invalidate(ownBookingsProvider);
  }

  Future<bool?> _confirmDialog(String message, String confirmLabel,
      {String cancelLabel = 'Annulla'}) {
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
