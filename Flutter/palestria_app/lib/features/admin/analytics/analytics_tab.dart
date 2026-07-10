import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'clienti_detail.dart';
import 'fatturato_detail.dart';
import 'fiscal_report.dart';
import 'occupancy_detail.dart';
import 'prenotazioni_detail.dart';
import 'stats_charts.dart';

/// Tab Statistiche & Fatturato (spec-admin §8) — port della dashboard web
/// (admin-analytics.js): filtri periodo con confronto sul periodo precedente,
/// 4 stat card, grafico andamento prenotazioni, ripartizione per tipo,
/// orari più/meno richiesti e ultime prenotazioni. I pannelli di drill-down
/// e l'export fiscale arrivano nello stadio successivo.
class AnalyticsTab extends ConsumerStatefulWidget {
  const AnalyticsTab({super.key});

  @override
  ConsumerState<AnalyticsTab> createState() => _AnalyticsTabState();
}

/// Range di date [from, to] inclusi (mezzanotte → 23:59:59.999).
typedef _Range = ({DateTime from, DateTime to});

const _months = [
  'Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
  'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'
];
const _monthsShort = [
  'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
  'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
];

class _AnalyticsTabState extends ConsumerState<AnalyticsTab> {
  String _filter = 'this-month';

  /// Pannello drill-down aperto: fatturato|prenotazioni|clienti|occupancy|null.
  String? _detail;

  /// True mentre si genera/condivide il report fiscale.
  bool _generating = false;

  static const _filters = {
    'this-month': 'Questo mese',
    'next-month': 'Mese prossimo',
    'last-month': 'Mese scorso',
    'this-year': 'Quest\'anno',
    'last-year': 'Anno scorso',
  };

  // ── Range per filtro (mirror di getFilterDateRange) ─────────────────────────
  _Range _rangeFor(String f) {
    final now = DateTime.now();
    DateTime endOfMonth(int y, int m) => DateTime(y, m + 1, 0, 23, 59, 59, 999);
    return switch (f) {
      'next-month' => (
          from: DateTime(now.year, now.month + 1),
          to: endOfMonth(now.year, now.month + 1)
        ),
      'last-month' => (
          from: DateTime(now.year, now.month - 1),
          to: endOfMonth(now.year, now.month - 1)
        ),
      'this-year' => (
          from: DateTime(now.year),
          to: DateTime(now.year, 12, 31, 23, 59, 59, 999)
        ),
      'last-year' => (
          from: DateTime(now.year - 1),
          to: DateTime(now.year - 1, 12, 31, 23, 59, 59, 999)
        ),
      _ => (
          from: DateTime(now.year, now.month),
          to: endOfMonth(now.year, now.month)
        ),
    };
  }

  /// Periodo di confronto (mirror di getPreviousFilterDateRange). null = nessuno.
  _Range? _prevRangeFor(String f) {
    final now = DateTime.now();
    DateTime endOfMonth(int y, int m) => DateTime(y, m + 1, 0, 23, 59, 59, 999);
    return switch (f) {
      'this-month' => (
          from: DateTime(now.year, now.month - 1),
          to: endOfMonth(now.year, now.month - 1)
        ),
      'next-month' => (
          from: DateTime(now.year, now.month),
          to: endOfMonth(now.year, now.month)
        ),
      'last-month' => (
          from: DateTime(now.year, now.month - 2),
          to: endOfMonth(now.year, now.month - 2)
        ),
      'this-year' => (
          from: DateTime(now.year - 1),
          to: DateTime(now.year - 1, 12, 31, 23, 59, 59, 999)
        ),
      'last-year' => (
          from: DateTime(now.year - 2),
          to: DateTime(now.year - 2, 12, 31, 23, 59, 59, 999)
        ),
      _ => null,
    };
  }

  String _filterLabel(String f) {
    final now = DateTime.now();
    return switch (f) {
      'next-month' => '${_months[(now.month) % 12]} '
          '${now.month == 12 ? now.year + 1 : now.year}',
      'last-month' => '${_months[(now.month - 2 + 12) % 12]} '
          '${now.month == 1 ? now.year - 1 : now.year}',
      'this-year' => '${now.year}',
      'last-year' => '${now.year - 1}',
      _ => '${_months[now.month - 1]} ${now.year}',
    };
  }

  String _prevLabel(String f) {
    final now = DateTime.now();
    return switch (f) {
      'this-month' => _months[(now.month - 2 + 12) % 12],
      'next-month' => _months[now.month - 1],
      'last-month' => _months[(now.month - 3 + 12) % 12],
      'this-year' => '${now.year - 1}',
      'last-year' => '${now.year - 2}',
      _ => 'periodo prec.',
    };
  }

  bool _inRange(String ymd, _Range r) {
    final d = DateTime.tryParse(ymd);
    return d != null && !d.isBefore(r.from) && !d.isAfter(r.to);
  }

  void _toggle(String key) =>
      setState(() => _detail = _detail == key ? null : key);

  /// Report fiscale: conferma (egress pesante) → fetch intero ledger + profili →
  /// genera e condivide il PDF (port di downloadFiscalReport).
  Future<void> _downloadFiscalReport() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scarica report fiscale'),
        content: const Text(
            'Verrà generato un PDF con l\'intero archivio dei pagamenti '
            'tracciati fiscalmente (carta, bonifico, Stripe, contanti con '
            'report). L\'operazione può richiedere tempo e traffico dati. '
            'Procedere?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Scarica')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _generating = true);
    try {
      final repo = await ref.read(adminRepositoryProvider.future);
      if (repo == null) throw Exception('Non autorizzato.');
      final payments = await repo.fetchPayments(); // intero ledger
      final profiles = await ref.read(adminProfilesProvider.future);
      final studio = ref
          .read(orgSettingsProvider)
          .value
          ?.getString('branding.studio_name', '');
      final n = await shareFiscalReport(
        payments: payments,
        profiles: profiles,
        studioName: studio,
      );
      messenger.showSnackBar(
          SnackBar(content: Text('Report generato: $n pagamenti fiscali.')));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Errore durante la generazione: $e')));
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// Pannello drill-down aperto (tap su una stat card). null → niente.
  Widget _detailPanel(_Range range, List<Booking> all,
      OrgSettingsService? settings, OrgScheduleConfig? config) {
    final label = _filterLabel(_filter);
    return switch (_detail) {
      'fatturato' => FatturatoDetail(
          from: range.from,
          to: range.to,
          filterLabel: label,
          bookings: all,
          settings: settings,
          config: config,
        ),
      'prenotazioni' => PrenotazioniDetail(
          from: range.from,
          to: range.to,
          filterLabel: label,
          bookings: all,
          config: config,
        ),
      'clienti' => ClientiDetail(
          from: range.from,
          to: range.to,
          prevFrom: _prevRangeFor(_filter)?.from,
          prevTo: _prevRangeFor(_filter)?.to,
          filterLabel: label,
          bookings: all,
        ),
      'occupancy' => OccupancyDetail(
          from: range.from,
          to: range.to,
          filterLabel: label,
          bookings: all,
          config: config,
        ),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final bookingsAsync = ref.watch(statsBookingsProvider);
    final settings = ref.watch(orgSettingsProvider).value;
    final config = ref.watch(scheduleConfigProvider).value;

    return bookingsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore nel caricamento delle statistiche.',
        onRetry: () {
          ref.invalidate(statsBookingsProvider);
          ref.invalidate(statsPaymentsProvider);
        },
      ),
      data: (allRaw) {
        // Escludi cancellate e admin (come _excludeAdminBookings web).
        final all = allRaw
            .where((b) => !isAdminStatsEmail(b.email))
            .toList();
        final range = _rangeFor(_filter);
        final prevRange = _prevRangeFor(_filter);
        final filtered = all
            .where((b) => b.status != 'cancelled' && _inRange(b.date, range))
            .toList();

        double revenue(Iterable<Booking> bs) => bs
            .where((b) => b.paymentMethod != 'lezione-gratuita')
            .fold<double>(0, (s, b) => s + bookingPrice(b, settings, config));

        final rev = revenue(filtered);
        final bookingsCount = filtered.length;
        final activeClients = filtered
            .map((b) => (b.email ?? b.name ?? '').toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet()
            .length;

        // Confronto col periodo precedente (mai su range custom).
        double? revChange, bookChange;
        if (prevRange != null) {
          final prevFiltered = all
              .where((b) =>
                  b.status != 'cancelled' && _inRange(b.date, prevRange))
              .toList();
          final prevRev = revenue(prevFiltered);
          if (prevRev > 0) revChange = ((rev - prevRev) / prevRev) * 100;
          if (prevFiltered.isNotEmpty) {
            bookChange =
                ((bookingsCount - prevFiltered.length) / prevFiltered.length) *
                    100;
          }
        }

        final occupancy = _occupancy(filtered.length, range, config);

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(statsBookingsProvider);
            ref.invalidate(statsPaymentsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: const [
                  Text('Statistiche', style: AppText.pageTitle),
                  SizedBox(width: 6),
                  Text('& Fatturato',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.subtle)),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              _filterBar(),
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  _statCard('💰', 'Fatturato previsto', '€${_fmt(rev)}',
                      AppColors.amber, revChange,
                      active: _detail == 'fatturato',
                      onTap: () => _toggle('fatturato')),
                  const SizedBox(width: AppSpacing.md),
                  _statCard('📅', 'Prenotazioni', '$bookingsCount',
                      AppColors.blue500, bookChange,
                      active: _detail == 'prenotazioni',
                      onTap: () => _toggle('prenotazioni')),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _statCard('👥', 'Clienti attivi', '$activeClients',
                      Theme.of(context).colorScheme.primary, null,
                      subtitle: _filterLabel(_filter),
                      active: _detail == 'clienti',
                      onTap: () => _toggle('clienti')),
                  const SizedBox(width: AppSpacing.md),
                  _statCard(
                      '📈',
                      'Occupazione',
                      occupancy == null ? '—' : '$occupancy%',
                      AppColors.successEmerald,
                      null,
                      subtitle: _filterLabel(_filter),
                      positive: occupancy != null && occupancy > 50,
                      active: _detail == 'occupancy',
                      onTap: () => _toggle('occupancy')),
                ],
              ),
              _detailPanel(range, all, settings, config),
              const SizedBox(height: AppSpacing.lg),
              _chartCard(
                'Andamento prenotazioni',
                BookingsLineChart(
                  labels: _lineLabels(range),
                  values: _lineValues(filtered, range),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _chartCard(
                'Ripartizione per tipo',
                TypeDonutChart(slices: _typeSlices(filtered, config)),
              ),
              const SizedBox(height: AppSpacing.md),
              _popularTimesCard(filtered),
              const SizedBox(height: AppSpacing.md),
              _recentBookingsCard(filtered, config),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Il fatturato previsto è una proiezione dal valore delle '
                'prenotazioni (escluse le gratuite). L\'incassato reale dal '
                'registro pagamenti è nel dettaglio Fatturato.',
                style: TextStyle(fontSize: 12, color: AppColors.subtle),
              ),
              const SizedBox(height: AppSpacing.lg),
              OutlinedButton.icon(
                onPressed: _generating ? null : _downloadFiscalReport,
                icon: _generating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.description_outlined, size: 18),
                label: Text(_generating
                    ? 'Generazione...'
                    : 'Scarica report fiscale (PDF)'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Occupazione: prenotazioni / capienza totale programmata nel periodo ─────
  int? _occupancy(int bookings, _Range range, OrgScheduleConfig? config) {
    if (config == null) return null;
    var totalSlots = 0;
    var day = DateTime(range.from.year, range.from.month, range.from.day);
    final end = DateTime(range.to.year, range.to.month, range.to.day);
    var guard = 0;
    while (!day.isAfter(end) && guard < 800) {
      for (final slot in config.daySchedule(day).values) {
        totalSlots += slot.capacity;
      }
      day = day.add(const Duration(days: 1));
      guard++;
    }
    if (totalSlots == 0) return null;
    return ((bookings / totalSlots) * 100).round();
  }

  // ── Grafico andamento: giornaliero se ≤60gg, altrimenti mensile ─────────────
  bool _useMonthly(_Range r) => r.to.difference(r.from).inDays > 60;

  List<String> _lineLabels(_Range r) {
    if (_useMonthly(r)) {
      final out = <String>[];
      var y = r.from.year, m = r.from.month;
      while (y < r.to.year || (y == r.to.year && m <= r.to.month)) {
        out.add(_monthsShort[m - 1]);
        m++;
        if (m > 12) { m = 1; y++; }
      }
      return out;
    }
    final out = <String>[];
    var d = DateTime(r.from.year, r.from.month, r.from.day);
    final end = DateTime(r.to.year, r.to.month, r.to.day);
    while (!d.isAfter(end)) {
      out.add('${d.day}');
      d = d.add(const Duration(days: 1));
    }
    return out;
  }

  List<num> _lineValues(List<Booking> bs, _Range r) {
    if (_useMonthly(r)) {
      final out = <num>[];
      var y = r.from.year, m = r.from.month;
      while (y < r.to.year || (y == r.to.year && m <= r.to.month)) {
        final yy = y, mm = m;
        out.add(bs.where((b) {
          final d = DateTime.tryParse(b.date);
          return d != null && d.year == yy && d.month == mm;
        }).length);
        m++;
        if (m > 12) { m = 1; y++; }
      }
      return out;
    }
    final counts = <String, int>{};
    for (final b in bs) {
      counts[b.date] = (counts[b.date] ?? 0) + 1;
    }
    final out = <num>[];
    var d = DateTime(r.from.year, r.from.month, r.from.day);
    final end = DateTime(r.to.year, r.to.month, r.to.day);
    while (!d.isAfter(end)) {
      final ymd = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      out.add(counts[ymd] ?? 0);
      d = d.add(const Duration(days: 1));
    }
    return out;
  }

  List<DonutSlice> _typeSlices(List<Booking> bs, OrgScheduleConfig? config) {
    final byType = <String, int>{};
    for (final b in bs) {
      byType[b.slotType] = (byType[b.slotType] ?? 0) + 1;
    }
    final entries = byType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in entries)
        DonutSlice(
          config?.slotName(e.key) ?? e.key,
          e.value,
          config?.slotColor(e.key) ?? AppColors.primary,
        ),
    ];
  }

  // ── UI helpers ──────────────────────────────────────────────────────────────
  Widget _filterBar() {
    final cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in _filters.entries)
            GestureDetector(
              onTap: () => setState(() => _filter = entry.key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: _filter == entry.key
                          ? cs.primary
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
                child: Text(entry.value,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: _filter == entry.key ? cs.secondary : AppColors.muted)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statCard(String emoji, String label, String value, Color color,
      double? changePct,
      {String? subtitle,
      bool positive = false,
      VoidCallback? onTap,
      bool active = false}) {
    Widget change;
    if (changePct != null) {
      final pos = changePct >= 0;
      change = Text(
        '${pos ? '+' : ''}${changePct.round()}% vs ${_prevLabel(_filter)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: pos ? AppColors.successEmeraldDark : AppColors.dangerDark),
      );
    } else {
      change = Text(
        subtitle ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: positive ? AppColors.successEmeraldDark : AppColors.subtle),
      );
    }
    // Barra colore in alto (flush, segue il raggio della card) + bordo/ombra
    // evidenziati quando il pannello è aperto (stato "active").
    return Expanded(
      child: AppCard(
        onTap: onTap,
        radius: AppRadius.cardLg,
        borderColor: active ? color : AppColors.border,
        elevated: active,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(height: 3, color: color),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                      const Spacer(),
                      if (onTap != null)
                        Icon(active ? Icons.expand_less : Icons.expand_more,
                            size: 18, color: AppColors.subtle),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(label.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Color(0xFF9CA3AF))),
                  const SizedBox(height: 2),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111111),
                          fontFeatures: AppText.tabularNums)),
                  const SizedBox(height: 3),
                  change,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chartCard(String title, Widget child) {
    return AppCard(
      radius: AppRadius.cardLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.navy)),
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }

  Widget _popularTimesCard(List<Booking> bs) {
    final counts = <String, int>{};
    for (final b in bs) {
      counts[b.time] = (counts[b.time] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (sorted.isEmpty) {
      return _chartCard('Orari più richiesti',
          const Text('Nessun dato nel periodo', style: AppText.meta));
    }
    final top = sorted.take(5).toList();
    final maxV = top.first.value;
    return _chartCard(
      'Orari più richiesti',
      Column(
        children: [
          for (final e in top)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(e.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: e.value / maxV,
                        minHeight: 16,
                        backgroundColor: const Color(0xFFF1F5F9),
                        valueColor: const AlwaysStoppedAnimation(
                            AppColors.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${e.value}',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _recentBookingsCard(List<Booking> bs, OrgScheduleConfig? config) {
    final sorted = [...bs]..sort((a, b) {
        if (a.date != b.date) return b.date.compareTo(a.date);
        return b.time.compareTo(a.time);
      });
    final rows = sorted.take(15).toList();
    return _chartCard(
      'Ultime prenotazioni',
      rows.isEmpty
          ? const Text('Nessuna prenotazione nel periodo', style: AppText.meta)
          : Column(
              children: [
                for (final b in rows) _bookingRow(b, config),
              ],
            ),
    );
  }

  Widget _bookingRow(Booking b, OrgScheduleConfig? config) {
    final parts = b.date.split('-');
    final dateStr = parts.length == 3
        ? '${int.parse(parts[2])}/${int.parse(parts[1])}'
        : b.date;
    final (badgeBg, badgeFg, badgeText) = switch (b.status) {
      'cancellation_requested' => (
          const Color(0xFFFEF3C7),
          const Color(0xFFB45309),
          'Rich. annullo'
        ),
      'cancelled' => (
          const Color(0xFFFEE2E2),
          AppColors.dangerDark,
          'Annullata'
        ),
      _ => (const Color(0xFFDCFCE7), AppColors.successEmeraldDark, 'Confermata'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 68,
            child: Text('$dateStr · ${b.time.split(' - ').first}',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.muted)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name ?? '—',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                Text(config?.slotName(b.slotType) ?? b.slotType,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.subtle)),
              ],
            ),
          ),
          StatusPill(label: badgeText, background: badgeBg, foreground: badgeFg, dense: true),
        ],
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}
