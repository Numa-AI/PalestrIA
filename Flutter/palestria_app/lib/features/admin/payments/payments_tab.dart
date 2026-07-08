import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/normalize.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../client/booking/booking_providers.dart';
import 'pay_debt_sheet.dart';

/// Contatto con debito (prenotazioni passate non pagate).
class DebtorContact {
  DebtorContact({
    required this.name,
    this.whatsapp,
    this.email,
    required this.bookings,
    required this.total,
  });
  final String name;
  final String? whatsapp;
  final String? email;
  final List<Booking> bookings;
  final double total;
}

/// Tab Pagamenti (spec-admin §7): "Da incassare" (debitori) + "Incassato
/// questo mese", con popup di saldo → admin_pay_bookings.
class PaymentsTab extends ConsumerStatefulWidget {
  const PaymentsTab({super.key});

  @override
  ConsumerState<PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends ConsumerState<PaymentsTab> {
  bool _showDebtors = false;
  bool _showRecent = false;
  final Set<String> _openCards = {};

  @override
  Widget build(BuildContext context) {
    final bookingsAsync = ref.watch(adminBookingsProvider);
    final paymentsAsync = ref.watch(monthPaymentsProvider);
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();

    return bookingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Errore: $e')),
      data: (bookings) {
        final debtors = _computeDebtors(bookings);
        final totalUnpaid =
            debtors.fold<double>(0, (s, d) => s + d.total);
        final payments = paymentsAsync.value ?? const <PaymentRow>[];
        final monthRevenue =
            payments.fold<double>(0, (s, p) => s + p.amount);

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminBookingsProvider);
            ref.invalidate(monthPaymentsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
            children: [
              const Text('Pagamenti', style: AppText.pageTitle),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _statCard(
                    '💰',
                    'Da Incassare',
                    '€${_fmt(totalUnpaid)}',
                    const Color(0xFFEF4444),
                    active: _showDebtors,
                    onTap: () => setState(() {
                      _showDebtors = !_showDebtors;
                      if (_showDebtors) _showRecent = false;
                    }),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _statCard(
                    '💳',
                    'Incassato questo mese',
                    '€${_fmt(monthRevenue)}',
                    const Color(0xFF16A34A),
                    active: _showRecent,
                    onTap: () => setState(() {
                      _showRecent = !_showRecent;
                      if (_showRecent) _showDebtors = false;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_showDebtors) _debtorsList(config, debtors),
              if (_showRecent) _recentList(payments),
            ],
          ),
        );
      },
    );
  }

  List<DebtorContact> _computeDebtors(List<Booking> bookings) {
    final now = DateTime.now();
    // Stesso prezzo del server (admin_pay_bookings = custom ?? default tipo) e
    // di analytics/registro: senza questo, i pay-per-session senza custom_price
    // valgono €0 e sparivano dalla lista debitori pur dovendo il prezzo pieno.
    final settings = ref.read(orgSettingsProvider).value;
    final config = ref.read(scheduleConfigProvider).value;
    final byKey = <String, DebtorContact>{};
    final order = <String>[];

    String keyOf(String? email, String? whatsapp) {
      if (email != null && email.isNotEmpty) return 'e:${email.toLowerCase()}';
      if (whatsapp != null && whatsapp.isNotEmpty) {
        return 'p:${normalizePhone(whatsapp)}';
      }
      return 'x:${identityHashCode(whatsapp)}';
    }

    for (final b in bookings) {
      if (b.paid ||
          b.status == 'cancelled' ||
          b.status == 'cancellation_requested') {
        continue;
      }
      if (lessonStart(b.date, b.time).isAfter(now)) continue; // solo passate
      final price = bookingPrice(b, settings, config);
      final k = keyOf(b.email, b.whatsapp);
      final existing = byKey[k];
      if (existing == null) {
        byKey[k] = DebtorContact(
          name: b.name ?? '—',
          whatsapp: b.whatsapp,
          email: b.email,
          bookings: [b],
          total: price,
        );
        order.add(k);
      } else {
        byKey[k] = DebtorContact(
          name: existing.name,
          whatsapp: existing.whatsapp ?? b.whatsapp,
          email: existing.email ?? b.email,
          bookings: [...existing.bookings, b],
          total: existing.total + price,
        );
      }
    }
    final list = [for (final k in order) byKey[k]!]
        .where((d) => d.total > 0)
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  Widget _statCard(
      String emoji, String label, String value, Color color,
      {required bool active, required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: active ? color : const Color(0x0F000000),
                width: active ? 1.5 : 1),
            boxShadow: AppShadows.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(label.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: Color(0xFF9CA3AF))),
              Text(value,
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: AppText.tabularNums)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _debtorsList(OrgScheduleConfig config, List<DebtorContact> debtors) {
    if (debtors.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text('Nessun cliente con pagamenti in sospeso! 🎉',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppColors.subtle,
                fontStyle: FontStyle.italic,
                fontSize: 14)),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < debtors.length; i++)
          _debtorCard(config, debtors[i], i),
      ],
    );
  }

  Widget _debtorCard(OrgScheduleConfig config, DebtorContact d, int index) {
    final open = _openCards.contains('$index');
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: const BorderSide(color: Color(0xFFEF4444), width: 4),
          top: BorderSide(color: const Color(0xFFE5E7EB)),
          right: BorderSide(color: const Color(0xFFE5E7EB)),
          bottom: BorderSide(color: const Color(0xFFE5E7EB)),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              open ? _openCards.remove('$index') : _openCards.add('$index');
            }),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.name,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        Text('📱 ${d.whatsapp ?? '—'}',
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF666666))),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0x14EF4444),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('Da incassare: €${_fmt(d.total)}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFEF4444))),
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: [
                  for (final b in d.bookings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                                '📅 ${_shortDate(b.date)} · 🕐 ${b.time} · ${config.slotName(b.slotType)}',
                                style: const TextStyle(fontSize: 12.5)),
                          ),
                          Text(
                              '€${_fmt(bookingPrice(b, ref.read(orgSettingsProvider).value, config))}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFEF4444))),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton(
                    onPressed: () => _payDebt(d),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(42)),
                    child: const Text('✓ Segna come pagato'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recentList(List<PaymentRow> payments) {
    if (payments.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text('Nessun pagamento registrato',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppColors.subtle,
                fontStyle: FontStyle.italic,
                fontSize: 14)),
      );
    }
    return Column(
      children: [
        for (final p in payments)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.clientEmail ?? '—',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 14)),
                      Text(
                          '📅 ${p.createdAt == null ? '' : _shortDate(p.createdAt!.toIso8601String().substring(0, 10))} · ${PaymentRow.kindLabels[p.kind] ?? p.kind} · ${PaymentRow.methodLabels[p.method] ?? p.method}',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.muted)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0x1422C55E),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('€${_fmt(p.amount)}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF16A34A))),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _payDebt(DebtorContact d) async {
    final paid = await showPayDebtSheet(context, ref, d);
    if (paid == true) {
      ref.invalidate(adminBookingsProvider);
      ref.invalidate(monthPaymentsProvider);
    }
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  static String _shortDate(String ymd) {
    final d = DateTime.parse(ymd);
    return '${d.day}/${d.month}';
  }
}
