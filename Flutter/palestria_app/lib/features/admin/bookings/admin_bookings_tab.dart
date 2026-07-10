import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/booking/booking_providers.dart';
import 'add_participant_sheet.dart';

/// Tab Prenotazioni admin (spec-admin §3): week-bar, selettore giorni,
/// vista giornaliera con slot card e card partecipante.
class AdminBookingsTab extends ConsumerStatefulWidget {
  const AdminBookingsTab({super.key});

  @override
  ConsumerState<AdminBookingsTab> createState() => _AdminBookingsTabState();
}

class _AdminBookingsTabState extends ConsumerState<AdminBookingsTab> {
  int _weekOffset = 0;
  DateTime? _selectedDay;

  static const _dayNames = [
    'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato', 'Domenica'
  ];
  static const _monthShort = [
    'gen', 'feb', 'mar', 'apr', 'mag', 'giu',
    'lug', 'ago', 'set', 'ott', 'nov', 'dic'
  ];

  DateTime _weekMonday(int offset) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    return monday.add(Duration(days: 7 * offset));
  }

  List<DateTime> _weekDays(int offset) {
    final m = _weekMonday(offset);
    return [for (var i = 0; i < 7; i++) m.add(Duration(days: i))];
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(scheduleConfigProvider);
    final overridesAsync = ref.watch(scheduleOverridesProvider);
    final bookingsAsync = ref.watch(adminBookingsProvider);

    if (configAsync.isLoading || bookingsAsync.isLoading) {
      return const AppLoading();
    }
    if (configAsync.hasError || bookingsAsync.hasError) {
      return AppErrorRetry(
        onRetry: () {
          ref.invalidate(scheduleConfigProvider);
          ref.invalidate(scheduleOverridesProvider);
          ref.invalidate(adminBookingsProvider);
        },
      );
    }
    final config = configAsync.value ?? OrgScheduleConfig.empty();
    final overrides = overridesAsync.value ?? const {};
    final bookings = bookingsAsync.value ?? const <Booking>[];

    final days = _weekDays(_weekOffset);
    var selected = _selectedDay;
    if (selected == null ||
        !days.any((d) => d.day == selected!.day && d.month == selected.month)) {
      final today = DateTime.now();
      selected = days.firstWhere(
        (d) => d.year == today.year && d.month == today.month && d.day == today.day,
        orElse: () => days.first,
      );
    }
    final selectedDay = selected;

    final daySlots = computeDaySlots(
      day: selectedDay,
      config: config,
      overrides: overrides,
      availability: const {},
      ownBookings: const [],
    );

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(adminBookingsProvider);
        ref.invalidate(scheduleOverridesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
        children: [
          _weekHero(days, selectedDay, bookings),
          const SizedBox(height: AppSpacing.lg),
          if (daySlots.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.xxl),
              child: Text('Nessuna lezione programmata per questo giorno',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.subtle,
                      fontStyle: FontStyle.italic,
                      fontSize: 14)),
            )
          else
            for (final slot in daySlots)
              _slotCard(config, slot, bookings, selectedDay),
        ],
      ),
    );
  }

  /// Hero scuro→viola (replica dell'hero admin del web): nav settimana + i giorni
  /// come chip "glass" sul gradiente. `DarkHero` porta gradiente+glow org-aware.
  Widget _weekHero(
      List<DateTime> days, DateTime selectedDay, List<Booking> bookings) {
    final range =
        '${days.first.day} ${_monthShort[days.first.month - 1]} — ${days.last.day} ${_monthShort[days.last.month - 1]}';
    final monthLabel = '${selectedDay.year}';

    return DarkHero(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          Row(
            children: [
              _navBtn(Icons.chevron_left, 'Settimana precedente', () {
                setState(() {
                  _weekOffset--;
                  _selectedDay = null;
                });
              }),
              Expanded(
                child: Column(
                  children: [
                    Text(range,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: Colors.white)),
                    Text(monthLabel,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: Colors.white.withValues(alpha: 0.72))),
                  ],
                ),
              ),
              _navBtn(Icons.chevron_right, 'Settimana successiva', () {
                setState(() {
                  _weekOffset++;
                  _selectedDay = null;
                });
              }),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _daySelector(days, selectedDay, bookings),
        ],
      ),
    );
  }

  Widget _navBtn(IconData icon, String tip, VoidCallback onTap) => IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
        tooltip: tip,
        style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.12)),
      );

  Widget _daySelector(
      List<DateTime> days, DateTime selected, List<Booking> bookings) {
    final today = DateTime.now();
    return Row(
      children: [
        for (final d in days)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _dayCard(
                d,
                isActive: d.day == selected.day && d.month == selected.month,
                isToday: d.year == today.year &&
                    d.month == today.month &&
                    d.day == today.day,
                count: bookings
                    .where((b) =>
                        b.date == OrgScheduleConfig.localDateStr(d) &&
                        b.status != 'cancelled')
                    .length,
              ),
            ),
          ),
      ],
    );
  }

  Widget _dayCard(DateTime d,
      {required bool isActive, required bool isToday, required int count}) {
    Gradient? gradient;
    // Chip "glass" sull'hero scuro: default translucido, attivo = gradiente pieno.
    Color bg = Colors.white.withValues(alpha: 0.08);
    Color fg = Colors.white.withValues(alpha: 0.72);

    if (isActive && isToday) {
      gradient =
          const LinearGradient(colors: [AppColors.danger, AppColors.dangerDark]);
      fg = Colors.white;
      bg = Colors.transparent;
    } else if (isActive) {
      gradient = brandGradient(context);
      fg = Colors.white;
      bg = Colors.transparent;
    } else if (isToday) {
      bg = Colors.white.withValues(alpha: 0.20);
      fg = Colors.white;
    }

    return GestureDetector(
      onTap: () => setState(() => _selectedDay = d),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        decoration: BoxDecoration(
          color: gradient == null ? bg : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(_dayNames[d.weekday - 1].substring(0, 3),
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
            Text('${d.day}',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w800, color: fg)),
            Text('$count pr.',
                style: TextStyle(
                    fontSize: 9,
                    color: fg.withValues(alpha: 0.85))),
          ],
        ),
      ),
    );
  }

  Widget _slotCard(OrgScheduleConfig config, DaySlot slot,
      List<Booking> allBookings, DateTime day) {
    final dateStr = OrgScheduleConfig.localDateStr(day);
    final slotBookings = allBookings
        .where((b) =>
            b.date == dateStr &&
            b.time == slot.time &&
            b.status != 'cancelled')
        .toList();
    final confirmed = slotBookings.length;
    final color = config.slotColor(slot.slotType);
    final isCleaning = slot.slotType == 'cleaning';

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: color, width: 4)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('🕐 ${slot.time}',
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                              fontFeatures: AppText.tabularNums)),
                      if (!isCleaning)
                        Text(
                            '$confirmed/${slot.capacity} ${slot.capacity == 1 ? 'posto' : 'posti'}',
                            style: const TextStyle(
                                fontSize: 12.5, color: AppColors.muted))
                      else
                        const Text('🧹 Pulizia',
                            style: TextStyle(
                                fontSize: 12.5, color: Color(0xFF8B5CF6))),
                    ],
                  ),
                ),
                if (!isCleaning)
                  IconButton(
                    onPressed: () => _addParticipant(config, slot, day),
                    icon: const Icon(Icons.add_circle_outline),
                    color: Theme.of(context).colorScheme.primary,
                    tooltip: 'Aggiungi prenotazione',
                  ),
              ],
            ),
          ),
          if (!isCleaning) ...[
            const Divider(height: 1),
            if (slotBookings.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Text('Nessuna prenotazione',
                    style: TextStyle(color: AppColors.subtle, fontSize: 13.5)),
              )
            else
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  children: [
                    for (final b in slotBookings) _participantCard(b),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _participantCard(Booking b) {
    final name = b.name ?? 'Anonimo';
    final hue = name.hashCode.abs() % AppColors.avatarTints.length;
    final (avBg, avFg) = AppColors.avatarTints[hue];
    final pending = b.status == 'cancellation_requested';
    final now = DateTime.now();
    final passed = lessonStart(b.date, b.time).isBefore(now);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: pending ? const Color(0xFFFFFBEB) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: pending ? const Color(0xFFFCD34D) : const Color(0xFFEEF0F3)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: avBg, shape: BoxShape.circle),
            child: Text(_initials(name),
                style: TextStyle(
                    color: avFg, fontWeight: FontWeight.w800, fontSize: 13)),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: Color(0xFF0F172A))),
                if (pending)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: StatusPill(
                      label: '⏳ Annullamento richiesto',
                      background: AppColors.cancelReqBg,
                      foreground: AppColors.cancelReqText,
                      dense: true,
                    ),
                  )
                else if (b.paid)
                  const Text('Pagato',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.paidText))
                else if (passed)
                  const Text('Da pagare',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFB45309))),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _deleteBooking(b),
            icon: const Icon(Icons.close, size: 18, color: Colors.white),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.dangerDark,
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addParticipant(
      OrgScheduleConfig config, DaySlot slot, DateTime day) async {
    final added = await showAddParticipantSheet(context, ref, slot, day);
    if (added == true) ref.invalidate(adminBookingsProvider);
  }

  Future<void> _deleteBooking(Booking b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
            'Confermare l\'annullamento della prenotazione di ${b.name ?? 'questo cliente'}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Indietro')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Conferma')),
        ],
      ),
    );
    if (ok != true || b.sbId == null) return;
    final repo = await ref.read(adminRepositoryProvider.future);
    if (repo == null) return;
    try {
      await repo.cancelBooking(b.sbId!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Prenotazione annullata con successo.')));
      }
      ref.invalidate(adminBookingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('⚠️ Errore: $e')));
      }
    }
  }

  static String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}
