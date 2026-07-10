import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Pannello drill-down "Clienti — Dettaglio" (port di renderClientiDetail,
/// admin-analytics.js): KPI (unici/nuovi/media lezioni/% con cancellazioni) +
/// classifiche (maggior fatturato dal ledger, più/meno attivi, top annullatori,
/// più fedeli, more, nuovi clienti, clienti persi vs periodo precedente).
class ClientiDetail extends ConsumerWidget {
  const ClientiDetail({
    super.key,
    required this.from,
    required this.to,
    required this.prevFrom,
    required this.prevTo,
    required this.filterLabel,
    required this.bookings,
  });

  final DateTime from;
  final DateTime to;
  final DateTime? prevFrom;
  final DateTime? prevTo;
  final String filterLabel;

  /// Prenotazioni org (finestra ampia, escluse admin), incluse cancellate.
  final List<Booking> bookings;

  static DateTime? _pd(String ymd) => DateTime.tryParse(ymd);
  static String _key(Booking b) =>
      (b.email?.toLowerCase().trim().isNotEmpty ?? false)
          ? b.email!.toLowerCase().trim()
          : (b.whatsapp?.trim().isNotEmpty ?? false)
              ? b.whatsapp!.trim()
              : (b.name ?? '').trim();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payments = ref.watch(statsPaymentsProvider).value ?? const <PaymentRow>[];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    bool inPeriod(DateTime d) => !d.isBefore(from) && !d.isAfter(to);

    // Mappa cliente → conteggi (prenotazioni nel periodo, incluse cancellate).
    final map = <String, _C>{};
    final nameByEmail = <String, String>{};
    for (final b in bookings) {
      if ((b.email?.isNotEmpty ?? false) && (b.name?.isNotEmpty ?? false)) {
        nameByEmail[b.email!.toLowerCase()] = b.name!;
      }
      final d = _pd(b.date);
      if (d == null || !inPeriod(d)) continue;
      final k = _key(b);
      final c = map.putIfAbsent(k, () => _C(b.name ?? k));
      if (b.status == 'cancelled') {
        c.cancelled++;
      } else {
        c.total++;
        if (!d.isBefore(today)) c.future++;
      }
    }

    final clients = map.values.toList();
    final active = clients.where((c) => c.total > 0).toList();
    final totalUnique = clients.length;
    final totalBookings = active.fold<int>(0, (s, c) => s + c.total);
    final avgBookings =
        active.isNotEmpty ? (totalBookings / active.length) : 0.0;
    final withCancel = clients.where((c) => c.cancelled > 0).length;
    final cancelRate =
        totalUnique > 0 ? (withCancel / totalUnique * 100).round() : 0;

    // Nuovi clienti: prima prenotazione (non cancellata) cade nel periodo.
    final firstByKey = <String, ({DateTime date, String name})>{};
    for (final b in bookings) {
      if (b.status == 'cancelled') continue;
      final d = _pd(b.date);
      if (d == null) continue;
      final k = _key(b);
      final cur = firstByKey[k];
      if (cur == null || d.isBefore(cur.date)) {
        firstByKey[k] = (date: d, name: b.name ?? k);
      }
    }
    final newClients = firstByKey.values
        .where((c) => inPeriod(c.date))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final topActive = [...active]..sort((a, b) => b.total.compareTo(a.total));
    final leastActive = [...active]..sort((a, b) => a.total.compareTo(b.total));
    final topCancellers = clients.where((c) => c.cancelled > 0).toList()
      ..sort((a, b) => b.cancelled.compareTo(a.cancelled));
    final mostLoyal = active.where((c) => c.cancelled == 0).toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    // Maggior fatturato versato (dal ledger payments, escluse gratuite).
    final cash = <String, ({String name, double cash})>{};
    final mora = <String, ({String name, int count, double total})>{};
    for (final p in payments) {
      final d = p.createdAt;
      if (d == null || !inPeriod(d)) continue;
      if (p.method == 'gratuito') continue;
      final ek = (p.clientEmail ?? '').toLowerCase();
      final k = ek.isNotEmpty ? ek : '(sconosciuto)';
      final name = nameByEmail[ek] ?? p.clientEmail ?? '(sconosciuto)';
      final prev = cash[k];
      cash[k] = (name: name, cash: (prev?.cash ?? 0) + p.amount);
      if (p.kind == 'penalty_mora' && p.amount > 0) {
        final m = mora[k];
        mora[k] = (
          name: name,
          count: (m?.count ?? 0) + 1,
          total: (m?.total ?? 0) + p.amount
        );
      }
    }
    final topCash = cash.values.where((c) => c.cash > 0).toList()
      ..sort((a, b) => b.cash.compareTo(a.cash));
    final moraList = mora.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final moraTotal = moraList.fold<double>(0, (s, c) => s + c.total);

    // Clienti persi: attivi nel periodo precedente, assenti nel corrente.
    final lost = <String>[];
    if (prevFrom != null && prevTo != null) {
      final prevKeys = <String, String>{};
      final currKeys = <String>{};
      for (final b in bookings) {
        if (b.status == 'cancelled') continue;
        final d = _pd(b.date);
        if (d == null) continue;
        final k = _key(b);
        if (!d.isBefore(prevFrom!) && !d.isAfter(prevTo!)) {
          prevKeys[k] = b.name ?? k;
        }
        if (inPeriod(d)) currKeys.add(k);
      }
      for (final e in prevKeys.entries) {
        if (!currKeys.contains(e.key)) lost.add(e.value);
      }
      lost.sort();
    }

    return AppCard(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      radius: AppRadius.cardLg,
      borderColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0x22 / 255),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('👥 Clienti — Dettaglio',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy)),
              ),
              Text(filterLabel,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.subtle)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _kpi(context, '$totalUnique', 'Clienti unici'),
              _kpi(context, '${newClients.length}', 'Nuovi clienti'),
              _kpi(context, avgBookings.toStringAsFixed(1), 'Media lez./cliente'),
              _kpi(context, '$cancelRate%', 'Con cancellazioni',
                  warn: cancelRate > 20),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _list('💰 Maggior fatturato (versato)',
              [for (final c in topCash.take(5)) (c.name, '€${_money(c.cash)}')]),
          _list('🏆 Più attivi nel periodo',
              [for (final c in topActive.take(5)) (c.name, '${c.total} lezioni')]),
          _list('💤 Meno attivi nel periodo',
              [for (final c in leastActive.take(5)) (c.name, '${c.total} lezioni')]),
          _list('❌ Top annullatori', [
            for (final c in topCancellers.take(5)) (c.name, '${c.cancelled} cancellaz.')
          ]),
          _list('⭐ Più fedeli (0 cancellazioni)',
              [for (final c in mostLoyal.take(5)) (c.name, '${c.total} lezioni')]),
          _list('💸 Pagamento more (${moraList.length}) — €${_money(moraTotal)}', [
            for (final c in moraList) (c.name, '${c.count} more — €${_money(c.total)}')
          ], emptyText: 'Nessuna mora nel periodo'),
          _list('🆕 Nuovi clienti (${newClients.length})', [
            for (final c in newClients)
              (c.name, '${c.date.day}/${c.date.month}/${c.date.year}')
          ], emptyText: 'Nessun nuovo cliente nel periodo'),
          _list('📉 Clienti persi (${lost.length})',
              [for (final n in lost) (n, '')],
              emptyText: 'Nessun cliente perso'),
        ],
      ),
    );
  }

  Widget _kpi(BuildContext context, String value, String label,
      {bool warn = false}) {
    return Container(
      width: (MediaQuery.of(context).size.width - 2 * AppSpacing.lg - AppSpacing.sm - 2) / 2,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: warn ? const Color(0xFFFEF2F2) : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: warn ? const Color(0x33EF4444) : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: warn ? AppColors.dangerDark : const Color(0xFF111111),
                  fontFeatures: AppText.tabularNums)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.subtle)),
        ],
      ),
    );
  }

  Widget _list(String title, List<(String, String)> rows,
      {String emptyText = 'Nessun dato'}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.navy)),
          const SizedBox(height: 4),
          if (rows.isEmpty)
            Text(emptyText, style: AppText.meta)
          else
            for (var i = 0; i < rows.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('${i + 1}. ${rows[i].$1}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                    if (rows[i].$2.isNotEmpty)
                      Text(rows[i].$2,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.muted)),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  static String _money(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

class _C {
  _C(this.name);
  final String name;
  int total = 0;
  int cancelled = 0;
  int future = 0;
}
