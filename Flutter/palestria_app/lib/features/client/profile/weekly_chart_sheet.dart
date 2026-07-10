import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import '../../admin/analytics/stats_charts.dart';
import '../booking/booking_providers.dart';

const _monthsShort = [
  'Gen',
  'Feb',
  'Mar',
  'Apr',
  'Mag',
  'Giu',
  'Lug',
  'Ago',
  'Set',
  'Ott',
  'Nov',
  'Dic',
];
const _past = AppColors.blue500;
const _future = Color(0xFFE63946);

/// Modal "Allenamenti settimanali/mensili" (port §7.6): barre = conteggio
/// prenotazioni non annullate; porzione passata blu + futura rossa.
/// Settimanale: 8 settimane (4 passate, corrente, 3 future). Mensile: 10 mesi.
class WeeklyChartSheet extends ConsumerStatefulWidget {
  const WeeklyChartSheet({super.key});

  @override
  ConsumerState<WeeklyChartSheet> createState() => _WeeklyChartSheetState();
}

class _WeeklyChartSheetState extends ConsumerState<WeeklyChartSheet> {
  bool _monthly = false;

  static DateTime? _pd(String ymd) => DateTime.tryParse(ymd);

  @override
  Widget build(BuildContext context) {
    final bookings = (ref.watch(ownBookingsProvider).value ?? const <Booking>[])
        .where((b) => b.status != 'cancelled')
        .toList();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final labels = <String>[];
    final solid = <num>[]; // passato (blu)
    final projected = <num>[]; // futuro (rosso)
    int highlight;

    if (_monthly) {
      highlight = 5;
      for (var i = -5; i <= 4; i++) {
        final mFrom = DateTime(now.year, now.month + i, 1);
        final mTo = DateTime(now.year, now.month + i + 1, 1);
        labels.add(_monthsShort[mFrom.month - 1]);
        var past = 0, fut = 0;
        for (final b in bookings) {
          final d = _pd(b.date);
          if (d == null || d.isBefore(mFrom) || !d.isBefore(mTo)) continue;
          if (d.isBefore(today)) {
            past++;
          } else {
            fut++;
          }
        }
        solid.add(past);
        projected.add(fut);
      }
    } else {
      highlight = 4;
      final monday = today.subtract(Duration(days: today.weekday - 1));
      for (var i = -4; i <= 3; i++) {
        final wFrom = monday.add(Duration(days: i * 7));
        final wTo = wFrom.add(const Duration(days: 7));
        labels.add('${wFrom.day}/${wFrom.month}');
        var past = 0, fut = 0;
        for (final b in bookings) {
          final d = _pd(b.date);
          if (d == null || d.isBefore(wFrom) || !d.isBefore(wTo)) continue;
          if (d.isBefore(today)) {
            past++;
          } else {
            fut++;
          }
        }
        solid.add(past);
        projected.add(fut);
      }
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _monthly
                        ? 'Allenamenti mensili'
                        : 'Allenamenti settimanali',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: () => setState(() => _monthly = !_monthly),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: Text(
                    _monthly ? 'Vista settimanale' : 'Vista mensile',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            MonthlyBarChart(
              labels: labels,
              solid: solid,
              projected: projected,
              highlightIndex: highlight,
              barColor: _past,
              projectedColor: _future,
              height: 220,
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legend(_past, 'Passati'),
                const SizedBox(width: AppSpacing.lg),
                _legend(_future, 'Futuri'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(Color c, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
    ],
  );
}

/// Apre il modal grafico allenamenti (§7.6).
void showWeeklyChart(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.modalLg),
      ),
    ),
    builder: (_) => const WeeklyChartSheet(),
  );
}
