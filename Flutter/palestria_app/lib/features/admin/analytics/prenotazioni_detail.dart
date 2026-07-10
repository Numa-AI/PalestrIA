import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'stats_charts.dart';

const _monthsShort = [
  'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
  'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
];
const _dayLabels = ['Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab', 'Dom'];

/// Pannello drill-down "Prenotazioni — Dettaglio" (port di
/// renderPrenotazioniDetail, admin-analytics.js): KPI (passate/future/stima/
/// media/cancellazioni), trend mensile 12+1, ripartizione per tipo, per giorno
/// della settimana, per fascia oraria e top-5 slot più comuni.
class PrenotazioniDetail extends StatelessWidget {
  const PrenotazioniDetail({
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

  /// Prenotazioni org (già escluse admin), incluse cancellate.
  final List<Booking> bookings;
  final OrgScheduleConfig? config;

  static DateTime? _pd(String ymd) => DateTime.tryParse(ymd);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final period = bookings.where((b) {
      final d = _pd(b.date);
      return b.status != 'cancelled' &&
          d != null &&
          !d.isBefore(from) &&
          !d.isAfter(to);
    }).toList();
    final past = period.where((b) => _pd(b.date)!.isBefore(today)).toList();
    final future = period.where((b) => !_pd(b.date)!.isBefore(today)).toList();
    final cancelled = bookings.where((b) {
      final d = _pd(b.date);
      return b.status == 'cancelled' &&
          d != null &&
          !d.isBefore(from) &&
          !d.isAfter(to);
    }).length;

    // Giorni programmati + futuri senza slot.
    var scheduledDays = 0, futureUnscheduledDays = 0;
    if (config != null) {
      var day = DateTime(from.year, from.month, from.day);
      final end = DateTime(to.year, to.month, to.day);
      var guard = 0;
      while (!day.isAfter(end) && guard < 800) {
        final has = config!.daySchedule(day).isNotEmpty;
        if (has) {
          scheduledDays++;
        } else if (!day.isBefore(today)) {
          futureUnscheduledDays++;
        }
        day = day.add(const Duration(days: 1));
        guard++;
      }
    }
    final totalDays = math.max(1, to.difference(from).inDays + 1);
    final weeklyAvg = scheduledDays > 0
        ? (period.length / scheduledDays * 7)
        : (period.length / totalDays * 7);
    final cancelRate = cancelled > 0
        ? (cancelled / (period.length + cancelled) * 100).round()
        : 0;
    final scheduleEstimate = (scheduledDays > 0 && futureUnscheduledDays > 0)
        ? period.length +
            (period.length / scheduledDays * futureUnscheduledDays).round()
        : period.length;

    // ── Trend mensile 12+1 ──────────────────────────────────────────────────
    int countIn(DateTime a, DateTime b) => bookings.where((x) {
          if (x.status == 'cancelled') return false;
          final d = _pd(x.date);
          return d != null && !d.isBefore(a) && d.isBefore(b);
        }).length;

    final cmFrom = DateTime(now.year, now.month, 1);
    final cmTo = DateTime(now.year, now.month + 1, 1);
    final cmActual = countIn(cmFrom, today);
    final cmFuture = countIn(today, cmTo);
    final cmDaysElapsed = math.max(today.day - 1, 1);
    final cmDaysTotal = DateTime(now.year, now.month + 1, 0).day;
    final cmLinear = (cmActual * cmDaysTotal / cmDaysElapsed).round();
    final cmEstimate = cmActual + math.max(cmFuture, math.max(cmLinear - cmActual, 0));

    final trendLabels = <String>[], solid = <num>[], projected = <num>[];
    for (var i = -11; i <= 1; i++) {
      final d = DateTime(now.year, now.month + i, 1);
      final mFrom = DateTime(d.year, d.month, 1);
      final mTo = DateTime(d.year, d.month + 1, 1);
      trendLabels.add(_monthsShort[d.month - 1] +
          (d.year != now.year ? " '${d.year % 100}" : ''));
      if (i == 0) {
        solid.add(cmActual);
        projected.add(math.max(0, cmEstimate - cmActual));
      } else if (i > 0) {
        solid.add(0);
        projected.add(countIn(mFrom, mTo));
      } else {
        solid.add(countIn(mFrom, mTo));
        projected.add(0);
      }
    }

    // ── Per tipo ────────────────────────────────────────────────────────────
    final byType = <String, int>{};
    for (final b in period) {
      byType[b.slotType] = (byType[b.slotType] ?? 0) + 1;
    }
    final typeSlices = [
      for (final e in (byType.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value))))
        DonutSlice(config?.slotName(e.key) ?? e.key, e.value,
            config?.slotColor(e.key) ?? AppColors.primary),
    ];

    // ── Per giorno della settimana (Lun..Dom) ───────────────────────────────
    final dayCounts = List<int>.filled(7, 0);
    for (final b in period) {
      final d = _pd(b.date);
      if (d != null) dayCounts[d.weekday - 1]++;
    }

    // ── Per fascia oraria + top slot ────────────────────────────────────────
    final timeMap = <String, int>{};
    final comboMap = <String, int>{};
    for (final b in period) {
      final t = b.time.isNotEmpty ? b.time.split(' - ').first : '?';
      timeMap[t] = (timeMap[t] ?? 0) + 1;
      final d = _pd(b.date);
      if (d != null) {
        final key = '${_dayLabels[d.weekday - 1]} $t';
        comboMap[key] = (comboMap[key] ?? 0) + 1;
      }
    }
    final timeSorted = timeMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final topSlots = comboMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final peakTime = timeSorted.isEmpty
        ? '—'
        : (timeSorted.reduce((a, b) => b.value > a.value ? b : a)).key;
    var peakDayIdx = 0;
    for (var i = 1; i < 7; i++) {
      if (dayCounts[i] > dayCounts[peakDayIdx]) peakDayIdx = i;
    }

    return AppCard(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      radius: AppRadius.cardLg,
      borderColor: AppColors.blue500.withValues(alpha: 0x22 / 255),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('📅 Prenotazioni — Dettaglio',
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
              _kpi(context, '${past.length}', 'Passate'),
              _kpi(context, '${future.length}', 'Future'),
              _kpi(context, '$scheduleEstimate', 'Stima futura'),
              _kpi(context, weeklyAvg.toStringAsFixed(1), 'Media sett.'),
              _kpi(context, '$cancelRate%', 'Cancellazioni',
                  warn: cancelRate > 5),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          _blockTitle('Trend mensile (ultimi 12 mesi + successivo)'),
          MonthlyBarChart(
            labels: trendLabels,
            solid: solid,
            projected: projected,
            highlightIndex: 11,
            barColor: AppColors.blue500,
          ),
          const SizedBox(height: AppSpacing.lg),
          _blockTitle('Per tipo di lezione'),
          TypeDonutChart(slices: typeSlices),
          const SizedBox(height: AppSpacing.lg),
          _blockTitle('Per giorno della settimana'),
          MonthlyBarChart(
            labels: _dayLabels,
            solid: dayCounts,
            barColor: AppColors.cyan,
            height: 130,
          ),
          const SizedBox(height: AppSpacing.lg),
          _blockTitle('Per fascia oraria'),
          _hBars(
              [for (final e in timeSorted) (e.key, e.value)],
              const Color(0xFFF97316)),
          const SizedBox(height: AppSpacing.lg),
          _blockTitle('Top 5 slot più comuni'),
          _hBars(
              [for (final e in topSlots.take(5)) (e.key, e.value)],
              AppColors.primary),
          const SizedBox(height: AppSpacing.md),
          _breakdownRow('Fascia oraria più popolare', peakTime),
          _breakdownRow('Giorno più popolare', _dayLabels[peakDayIdx]),
          _breakdownRow(
              'Stima futura (+$futureUnscheduledDays gg futuri senza slot)',
              '$scheduleEstimate'),
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

  Widget _kpi(BuildContext context, String value, String label,
      {bool warn = false}) {
    return Container(
      width: (MediaQuery.of(context).size.width - 2 * AppSpacing.lg - 2 * AppSpacing.sm - 4) / 3,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: warn ? AppColors.dangerDark : const Color(0xFF111111),
                  fontFeatures: AppText.tabularNums)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, color: AppColors.subtle)),
        ],
      ),
    );
  }

  Widget _hBars(List<(String, int)> rows, Color color) {
    if (rows.isEmpty) {
      return const Text('Nessun dato nel periodo', style: AppText.meta);
    }
    final maxV = rows.map((e) => e.$2).reduce(math.max);
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 78,
                  child: Text(r.$1,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                    child: LinearProgressIndicator(
                      value: maxV == 0 ? 0 : r.$2 / maxV,
                      minHeight: 14,
                      backgroundColor: const Color(0xFFF1F5F9),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${r.$2}',
                    style: const TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _breakdownRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12.5, color: Color(0xFF6B7280))),
            ),
            Text(value,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700)),
          ],
        ),
      );
}
