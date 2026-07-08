import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import 'stats_charts.dart';

const _monthsShort = [
  'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
  'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
];

/// Pannello drill-down "Fatturato — Dettaglio" (port di renderFatturatoDetail,
/// admin-analytics.js). Due modalità: **Prenotazioni** (proiezione dal valore
/// dei booking) e **Reale** (dal ledger `payments`). KPI + barre 12 mesi +
/// ripartizione (per tipo di lezione in Prenotazioni, per metodo in Reale).
class FatturatoDetail extends ConsumerStatefulWidget {
  const FatturatoDetail({
    super.key,
    required this.from,
    required this.to,
    required this.filterLabel,
    required this.bookings,
    required this.settings,
    required this.config,
  });

  final DateTime from;
  final DateTime to;
  final String filterLabel;

  /// Prenotazioni della org (già escluse admin), incluse cancellate.
  final List<Booking> bookings;
  final OrgSettingsService? settings;
  final OrgScheduleConfig? config;

  @override
  ConsumerState<FatturatoDetail> createState() => _FatturatoDetailState();
}

class _FatturatoDetailState extends ConsumerState<FatturatoDetail> {
  bool _reale = false;

  static DateTime? _pd(String ymd) => DateTime.tryParse(ymd);

  @override
  Widget build(BuildContext context) {
    final paymentsAsync = ref.watch(statsPaymentsProvider);
    final payments = paymentsAsync.value ?? const <PaymentRow>[];
    final paymentsUnavailable = _reale && paymentsAsync.hasError;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // In Reale i pagamenti di oggi sono già incassati → confine = domani.
    final pastCutoff =
        _reale ? today.add(const Duration(days: 1)) : today;

    double price(Booking b) => bookingPrice(b, widget.settings, widget.config);

    // Booking non-cancellati, esclusi i gratuiti.
    final valid = widget.bookings
        .where((b) =>
            b.status != 'cancelled' && b.paymentMethod != 'lezione-gratuita')
        .toList();
    final period = valid.where((b) {
      final d = _pd(b.date);
      return d != null &&
          !d.isBefore(widget.from) &&
          !d.isAfter(widget.to);
    }).toList();
    final past =
        period.where((b) => _pd(b.date)!.isBefore(pastCutoff)).toList();
    final future =
        period.where((b) => !_pd(b.date)!.isBefore(pastCutoff)).toList();

    double payInRange(DateTime a, DateTime b) => payments
        .where((p) =>
            p.createdAt != null &&
            !p.createdAt!.isBefore(a) &&
            p.createdAt!.isBefore(b))
        .fold<double>(0, (s, p) => s + p.amount);

    final pastRevenue = _reale
        ? payInRange(widget.from, pastCutoff)
        : past.fold<double>(0, (s, b) => s + price(b));
    final futureRevenue = _reale
        ? payInRange(pastCutoff, widget.to.add(const Duration(days: 1)))
        : future.fold<double>(0, (s, b) => s + price(b));

    // Giorni programmati nel periodo (per media settimanale + stima).
    var scheduledDays = 0, futureUnscheduledDays = 0;
    if (widget.config != null) {
      var day = DateTime(widget.from.year, widget.from.month, widget.from.day);
      final end = DateTime(widget.to.year, widget.to.month, widget.to.day);
      var guard = 0;
      while (!day.isAfter(end) && guard < 800) {
        final has = widget.config!.daySchedule(day).isNotEmpty;
        if (has) {
          scheduledDays++;
        } else if (!day.isBefore(pastCutoff)) {
          futureUnscheduledDays++;
        }
        day = day.add(const Duration(days: 1));
        guard++;
      }
    }
    final knownRev = pastRevenue + futureRevenue;
    final weeklyAvg =
        scheduledDays > 0 ? (knownRev / scheduledDays * 7).round() : 0;
    final scheduleEstimate =
        (scheduledDays > 0 && futureUnscheduledDays > 0)
            ? (knownRev + knownRev / scheduledDays * futureUnscheduledDays)
                .round()
            : knownRev.round();

    // ── Barre: 12 mesi + successivo ─────────────────────────────────────────
    final barLabels = <String>[], solid = <num>[], projected = <num>[];
    for (var i = -11; i <= 1; i++) {
      final d = DateTime(now.year, now.month + i, 1);
      final mFrom = DateTime(d.year, d.month, 1);
      final mTo = DateTime(d.year, d.month + 1, 1); // esclusivo
      barLabels.add(_monthsShort[d.month - 1] +
          (d.year != now.year ? " '${d.year % 100}" : ''));
      final isCurrent = i == 0, isFuture = i > 0;

      double bookRev(DateTime a, DateTime b) => valid
          .where((x) {
            final xd = _pd(x.date);
            return xd != null && !xd.isBefore(a) && xd.isBefore(b);
          })
          .fold<double>(0, (s, x) => s + price(x));

      if (isCurrent) {
        solid.add(_reale
            ? payInRange(mFrom, pastCutoff)
            : bookRev(mFrom, pastCutoff));
        projected.add(_reale ? 0 : bookRev(pastCutoff, mTo));
      } else if (isFuture) {
        solid.add(0);
        projected.add(_reale ? 0 : bookRev(mFrom, mTo));
      } else {
        solid.add(_reale ? payInRange(mFrom, mTo) : bookRev(mFrom, mTo));
        projected.add(0);
      }
    }
    final currentIdx = 11; // i=0 è l'undicesimo indice

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppShadows.card,
        border: Border.all(color: const Color(0x22F59E0B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('💰 Fatturato — Dettaglio',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.navy)),
              ),
              Text(widget.filterLabel,
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.subtle)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _modeTabs(),
          const SizedBox(height: AppSpacing.lg),
          _kpis(pastRevenue, futureRevenue, scheduleEstimate, weeklyAvg,
              payments, paymentsUnavailable),
          const SizedBox(height: AppSpacing.lg),
          const Text('Fatturato mensile (ultimi 12 mesi + successivo)',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted)),
          const SizedBox(height: 6),
          MonthlyBarChart(
            labels: barLabels,
            solid: solid,
            projected: _reale ? null : projected,
            highlightIndex: currentIdx,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
              _reale
                  ? 'Fatturato per tipo di pagamento'
                  : 'Fatturato per tipo di lezione',
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.muted)),
          const SizedBox(height: 6),
          _reale
              ? _byMethod(payments)
              : TypeDonutChart(slices: _byType(past, future, price)),
        ],
      ),
    );
  }

  Widget _modeTabs() {
    Widget tab(String label, bool active, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: active ? Colors.white : AppColors.muted)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          tab('Prenotazioni', !_reale, () => setState(() => _reale = false)),
          tab('Reale', _reale, () => setState(() => _reale = true)),
        ],
      ),
    );
  }

  Widget _kpis(double pastRev, double futureRev, int estimate, int weeklyAvg,
      List<PaymentRow> payments, bool unavailable) {
    String eur(num v) => unavailable && _reale ? '—' : '€${_fmt(v.toDouble())}';
    final cards = <(String, String)>[];
    if (_reale) {
      final periodMethodTotal = payments
          .where((p) =>
              p.createdAt != null &&
              !p.createdAt!.isBefore(widget.from) &&
              !p.createdAt!.isAfter(widget.to) &&
              p.method != 'gratuito')
          .fold<double>(0, (s, p) => s + p.amount);
      cards.add((eur(pastRev), 'Incassato'));
      cards.add((eur(periodMethodTotal), 'Fatturato reale'));
      cards.add((eur(weeklyAvg), 'Media settimanale'));
    } else {
      cards.add(('€${_fmt(pastRev)}', 'Prenotazioni fatte'));
      cards.add(('€${_fmt(futureRev)}', 'Prenotazioni future'));
      cards.add(('€$estimate', 'Stima futura'));
      cards.add(('€$weeklyAvg', 'Media settimanale'));
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final c in cards)
          Container(
            width: (MediaQuery.of(context).size.width - 2 * AppSpacing.lg - 40) / 2,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFA),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.$1,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111111),
                        fontFeatures: AppText.tabularNums)),
                const SizedBox(height: 2),
                Text(c.$2,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.subtle)),
              ],
            ),
          ),
      ],
    );
  }

  List<DonutSlice> _byType(
      List<Booking> past, List<Booking> future, double Function(Booking) price) {
    final rev = <String, double>{};
    for (final b in [...past, ...future]) {
      rev[b.slotType] = (rev[b.slotType] ?? 0) + price(b);
    }
    final entries = rev.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in entries)
        DonutSlice(
          widget.config?.slotName(e.key) ?? e.key,
          e.value,
          widget.config?.slotColor(e.key) ?? AppColors.primary,
        ),
    ];
  }

  Widget _byMethod(List<PaymentRow> payments) {
    const methodMeta = {
      'contanti': ('Contanti', Color(0xFF22C55E)),
      'contanti-report': ('Contanti con Report', Color(0xFFEF4444)),
      'carta': ('Carta', Color(0xFF3B82F6)),
      'iban': ('Bonifico', Color(0xFFF59E0B)),
      'stripe': ('Stripe', Color(0xFF635BFF)),
    };
    final periodPayments = payments.where((p) =>
        p.createdAt != null &&
        !p.createdAt!.isBefore(widget.from) &&
        !p.createdAt!.isAfter(widget.to));
    final byMethod = <String, double>{};
    double freeValue = 0;
    var freeCount = 0;
    for (final p in periodPayments) {
      if (p.method == 'gratuito') {
        freeValue += p.amount;
        freeCount++;
        continue;
      }
      byMethod[p.method] = (byMethod[p.method] ?? 0) + p.amount;
    }
    final slices = <DonutSlice>[];
    var other = 0.0;
    byMethod.forEach((k, v) {
      final meta = methodMeta[k];
      if (meta == null) {
        other += v;
      } else if (v > 0) {
        slices.add(DonutSlice(meta.$1, v, meta.$2));
      }
    });
    if (other > 0) {
      slices.add(DonutSlice('Altro', other, const Color(0xFF94A3B8)));
    }
    if (freeCount > 0) {
      slices.add(
          DonutSlice('Lezione gratuita', freeValue, const Color(0xFFA855F7)));
    }
    if (slices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('Nessun incasso registrato nel periodo',
            style: AppText.meta),
      );
    }
    return TypeDonutChart(slices: slices);
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
