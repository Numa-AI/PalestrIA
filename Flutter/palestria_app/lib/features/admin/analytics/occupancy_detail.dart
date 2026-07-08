import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import 'stats_charts.dart';

const _monthsShort = [
  'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
  'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
];
const _dayLabels = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];

/// Pannello drill-down "Occupazione — Dettaglio" (port di renderOccupancyDetail,
/// admin-analytics.js), org-aware: occupazione = prenotazioni / capienza
/// programmata (da `daySchedule`). KPI (totale + per-tipo + prenotazioni),
/// trend occupazione % per tipo (12+1 mesi), occupazione per giorno settimana.
class OccupancyDetail extends StatelessWidget {
  const OccupancyDetail({
    super.key,
    required this.from,
    required this.to,
    required this.filterLabel,
    required this.bookings,
    required this.config,
  });

  final DateTime from;
  final DateTime to;
  final String filterLabel;
  final List<Booking> bookings;
  final OrgScheduleConfig? config;

  static DateTime? _pd(String ymd) => DateTime.tryParse(ymd);

  /// Capienza programmata per tipo su [a,b] inclusi (da daySchedule).
  Map<String, int> _capByType(DateTime a, DateTime b) {
    final cap = <String, int>{};
    if (config == null) return cap;
    var day = DateTime(a.year, a.month, a.day);
    final end = DateTime(b.year, b.month, b.day);
    var guard = 0;
    while (!day.isAfter(end) && guard < 800) {
      for (final slot in config!.daySchedule(day).values) {
        cap[slot.slotTypeKey] = (cap[slot.slotTypeKey] ?? 0) + slot.capacity;
      }
      day = day.add(const Duration(days: 1));
      guard++;
    }
    return cap;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final valid = bookings.where((b) => b.status != 'cancelled').toList();
    final period = valid.where((b) {
      final d = _pd(b.date);
      return d != null && !d.isBefore(from) && !d.isAfter(to);
    }).toList();

    // ── Capienza + prenotazioni per tipo nel periodo ────────────────────────
    final capByType = _capByType(from, to);
    final bkByType = <String, int>{};
    for (final b in period) {
      bkByType[b.slotType] = (bkByType[b.slotType] ?? 0) + 1;
    }
    int rate(int bk, int cap) =>
        cap > 0 ? math.min(100, (bk / cap * 100).round()) : 0;
    final totCap = capByType.values.fold<int>(0, (s, v) => s + v);
    final totRate = rate(period.length, totCap);

    // Tipi ordinati per capienza (più rilevanti prima), con capienza > 0.
    final typeKeys = capByType.keys.where((k) => capByType[k]! > 0).toList()
      ..sort((a, b) => capByType[b]!.compareTo(capByType[a]!));

    // ── Trend occupazione % per tipo (12+1 mesi) ────────────────────────────
    List<num> trendFor(String key) {
      final out = <num>[];
      for (var i = 11; i >= -1; i--) {
        final mFrom = DateTime(now.year, now.month - i, 1);
        final mTo = DateTime(now.year, now.month - i + 1, 0);
        final cap = _capByType(mFrom, mTo)[key] ?? 0;
        final bk = valid.where((b) {
          final d = _pd(b.date);
          return b.slotType == key &&
              d != null &&
              !d.isBefore(mFrom) &&
              !d.isAfter(mTo);
        }).length;
        out.add(rate(bk, cap));
      }
      return out;
    }

    final trendLabels = <String>[];
    for (var i = 11; i >= -1; i--) {
      final d = DateTime(now.year, now.month - i, 1);
      trendLabels.add(_monthsShort[d.month - 1] +
          (d.year != now.year ? " '${d.year % 100}" : ''));
    }

    // ── Occupazione per giorno della settimana (Lun..Dom) ───────────────────
    final dowCap = List<int>.filled(7, 0);
    final dowBk = List<int>.filled(7, 0);
    if (config != null) {
      var day = DateTime(from.year, from.month, from.day);
      final end = DateTime(to.year, to.month, to.day);
      var guard = 0;
      while (!day.isAfter(end) && guard < 800) {
        for (final slot in config!.daySchedule(day).values) {
          dowCap[day.weekday - 1] += slot.capacity;
        }
        day = day.add(const Duration(days: 1));
        guard++;
      }
    }
    for (final b in period) {
      final d = _pd(b.date);
      if (d != null) dowBk[d.weekday - 1]++;
    }
    final dowRates = [for (var i = 0; i < 7; i++) rate(dowBk[i], dowCap[i])];

    final kpiTypes = typeKeys.take(2).toList();

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppShadows.card,
        border: Border.all(color: const Color(0x2210B981)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('📈 Occupazione — Dettaglio',
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
          if (totCap == 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                  'Nessuno slot programmato nel periodo: configura gli orari '
                  'per vedere l\'occupazione.',
                  style: AppText.meta),
            )
          else ...[
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _kpi(context, '$totRate%', 'Totale'),
                for (final k in kpiTypes)
                  _kpi(context, '${rate(bkByType[k] ?? 0, capByType[k]!)}%',
                      config?.slotName(k) ?? k),
                _kpi(context, '${period.length}', 'Prenotazioni'),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            for (final k in typeKeys.take(3)) ...[
              _blockTitle(
                  '${config?.slotName(k) ?? k} — occupazione ultimi 12 mesi + succ.'),
              MonthlyBarChart(
                labels: trendLabels,
                solid: trendFor(k),
                highlightIndex: 11,
                barColor: config?.slotColor(k) ?? AppColors.primary,
                height: 130,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            _blockTitle('Occupazione per giorno della settimana'),
            MonthlyBarChart(
              labels: _dayLabels,
              solid: dowRates,
              barColor: const Color(0xFF3B82F6),
              height: 130,
            ),
          ],
        ],
      ),
    );
  }

  Widget _blockTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: AppColors.muted)),
      );

  Widget _kpi(BuildContext context, String value, String label) {
    return Container(
      width: (MediaQuery.of(context).size.width - 2 * AppSpacing.lg - AppSpacing.sm - 2) / 2,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111111),
                  fontFeatures: AppText.tabularNums)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.subtle)),
        ],
      ),
    );
  }
}
