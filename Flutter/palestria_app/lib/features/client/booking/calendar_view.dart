import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_config.dart';
import '../../../core/theme/tokens.dart';
import 'booking_providers.dart';
import 'booking_sheet.dart';

/// Calendario prenotazioni — layout mobile della web app (§4.2 spec-client):
/// week-nav, selettore 7 giorni, lista card slot del giorno.
class CalendarView extends ConsumerStatefulWidget {
  const CalendarView({super.key});

  @override
  ConsumerState<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends ConsumerState<CalendarView> {
  int _weekOffset = 0;
  DateTime? _selectedDay;
  bool _autoAdvanced = false;

  /// Lunedì della settimana corrente + offset.
  DateTime _weekMonday(int offset) {
    final now = DateTime.now();
    final monday = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    return monday.add(Duration(days: 7 * offset));
  }

  List<DateTime> _weekDays(int offset) {
    final monday = _weekMonday(offset);
    return [for (var i = 0; i < 7; i++) monday.add(Duration(days: i))];
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(scheduleConfigProvider);
    final overridesAsync = ref.watch(scheduleOverridesProvider);
    final availabilityAsync = ref.watch(availabilityProvider);
    final ownAsync = ref.watch(ownBookingsProvider);

    if (configAsync.isLoading || overridesAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final config = configAsync.value ?? OrgScheduleConfig.empty();
    final overrides = overridesAsync.value ?? const {};
    final availability = availabilityAsync.value ?? const {};
    final own = ownAsync.value ?? const [];

    List<DaySlot> slotsOf(DateTime day) => computeDaySlots(
          day: day,
          config: config,
          overrides: overrides,
          availability: availability,
          ownBookings: own,
        );

    bool dayHasAvailable(DateTime day) {
      final today = DateTime.now();
      final startOfToday = DateTime(today.year, today.month, today.day);
      if (day.isBefore(startOfToday)) return false;
      return slotsOf(day).any((s) => !s.pastCutoff);
    }

    bool weekHasSlots(int offset) =>
        _weekDays(offset).any(dayHasAvailable);

    // Auto-advance: se la settimana corrente non ha più slot e la prossima sì.
    if (!_autoAdvanced) {
      _autoAdvanced = true;
      if (_weekOffset == 0 && !weekHasSlots(0) && weekHasSlots(1)) {
        _weekOffset = 1;
      }
    }

    final days = _weekDays(_weekOffset);

    // Selezione automatica del giorno (come il web).
    var selected = _selectedDay;
    if (selected == null ||
        !days.any((d) => d.day == selected!.day && d.month == selected.month)) {
      final today = DateTime.now();
      selected = days.firstWhere(
        (d) =>
            d.year == today.year &&
            d.month == today.month &&
            d.day == today.day &&
            dayHasAvailable(d),
        orElse: () => days.firstWhere(dayHasAvailable, orElse: () => days[0]),
      );
    }
    final selectedDay = selected;

    final daySlots =
        slotsOf(selectedDay).where((s) => !s.pastCutoff).toList();
    final hadSlots = slotsOf(selectedDay).isNotEmpty;

    final primary = Theme.of(context).colorScheme.primary;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(availabilityProvider);
        ref.invalidate(ownBookingsProvider);
        ref.invalidate(scheduleOverridesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _weekNav(primary, weekHasSlots),
          const SizedBox(height: AppSpacing.md),
          _daySelector(days, selectedDay, dayHasAvailable, own, primary),
          const SizedBox(height: AppSpacing.lg),
          if (daySlots.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.xxxl),
              child: Text(
                hadSlots
                    ? 'Nessuna lezione disponibile per questo giorno'
                    : 'Nessuna lezione programmata per questo giorno',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF999999), fontSize: 15),
              ),
            )
          else
            ...daySlots.map((s) => _slotCard(context, config, s)),
          const SizedBox(height: AppSpacing.xxxl),
        ],
      ),
    );
  }

  Widget _weekNav(Color primary, bool Function(int) weekHasSlots) {
    final days = _weekDays(_weekOffset);
    final label =
        '${days.first.day}/${days.first.month} – ${days.last.day}/${days.last.month}';
    final prevEnabled = _weekOffset > 0;
    final nextEnabled = weekHasSlots(_weekOffset + 1);

    Widget btn(String text, bool enabled, VoidCallback onTap) => Opacity(
          opacity: enabled ? 1 : 0.3,
          child: FilledButton(
            onPressed: enabled ? onTap : null,
            style: FilledButton.styleFrom(
              backgroundColor: primary,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 8),
              minimumSize: const Size(0, 36),
              textStyle:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
            child: Text(text),
          ),
        );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        btn('← Prec.', prevEnabled, () => setState(() {
              _weekOffset--;
              _selectedDay = null;
            })),
        Text(label,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.navy)),
        btn('Succ. →', nextEnabled, () => setState(() {
              _weekOffset++;
              _selectedDay = null;
            })),
      ],
    );
  }

  Widget _daySelector(
    List<DateTime> days,
    DateTime selected,
    bool Function(DateTime) dayHasAvailable,
    List<dynamic> own,
    Color primary,
  ) {
    bool hasEnrollment(DateTime d) {
      final ds = OrgScheduleConfig.localDateStr(d);
      return own.any((b) => b.date == ds && b.isOccupying == true);
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -200) {
          setState(() {
            _weekOffset++;
            _selectedDay = null;
          });
        } else if (v > 200 && _weekOffset > 0) {
          setState(() {
            _weekOffset--;
            _selectedDay = null;
          });
        }
      },
      child: Row(
        children: [
          for (final d in days)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: _dayCard(
                  d,
                  isActive: d.day == selected.day && d.month == selected.month,
                  disabled: !dayHasAvailable(d),
                  enrolled: hasEnrollment(d),
                  primary: primary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dayCard(
    DateTime d, {
    required bool isActive,
    required bool disabled,
    required bool enrolled,
    required Color primary,
  }) {
    // Stati come il web: active = gradiente viola (rosso se enrolled);
    // enrolled = tinta rossa; disabled = opacity 0.35.
    Gradient? gradient;
    Color bg = Colors.white;
    Color border = const Color(0xFFDDDDDD);
    Color fg = AppColors.textDark;

    if (isActive && enrolled) {
      gradient = const LinearGradient(
          colors: [Color(0xFFEF4444), Color(0xFFDC2626)]);
      fg = Colors.white;
    } else if (isActive) {
      gradient = LinearGradient(colors: [
        primary,
        Color.fromARGB(255, ((primary.r * 255) * 0.9).round(),
            ((primary.g * 255) * 0.9).round(), ((primary.b * 255) * 0.9).round())
      ]);
      fg = Colors.white;
    } else if (enrolled) {
      bg = const Color(0x1FEF4444);
      border = const Color(0x59EF4444);
    }

    return Opacity(
      opacity: disabled ? 0.35 : 1,
      child: GestureDetector(
        onTap: disabled
            ? null
            : () => setState(() => _selectedDay = d),
        child: AnimatedScale(
          scale: isActive ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
            decoration: BoxDecoration(
              color: gradient == null ? bg : null,
              gradient: gradient,
              border: gradient == null ? Border.all(color: border, width: 2) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                Text(kDayShort[d.weekday % 7],
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
                Text('${d.day}',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: fg)),
                Opacity(
                  opacity: 0.8,
                  child: Text(kMonthShort[d.month - 1],
                      style: TextStyle(fontSize: 10, color: fg)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _slotCard(
      BuildContext context, OrgScheduleConfig config, DaySlot slot) {
    final color = config.slotColor(slot.slotType);
    final name = config.slotName(slot.slotType);
    final isCleaning = slot.slotType == 'cleaning';
    final clickable = !isCleaning && (slot.bookable || slot.isFull || slot.enrolled);

    Widget trailing;
    if (slot.enrolled) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0x2622C55E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text('Qui ti alleni 💪🏼',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF16A34A))),
      );
    } else if (slot.bookable) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          slot.isFull
              ? 'Completo'
              : '${slot.remaining} disponibil${slot.remaining == 1 ? 'e' : 'i'}',
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: _spotsColor(slot.remaining),
          ),
        ),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return Opacity(
      opacity: slot.isFull && !slot.enrolled ? 0.5 : 1,
      child: GestureDetector(
        onTap: clickable ? () => showBookingSheet(context, ref, slot) : null,
        child: Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.sm),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              color.withValues(alpha: 0.22),
              color.withValues(alpha: 0.05),
            ]),
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border(left: BorderSide(color: color, width: 5)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x1A000000),
                  blurRadius: 8,
                  offset: Offset(0, 2)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('🕐 ${slot.time}',
                      style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111111),
                          fontFeatures: AppText.tabularNums)),
                  trailing,
                ],
              ),
              const SizedBox(height: 4),
              Text(isCleaning ? '🧹 Pulizia' : name,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333))),
            ],
          ),
        ),
      ),
    );
  }

  static Color _spotsColor(int n) => switch (n) {
        <= 1 => const Color(0xFFDC2626),
        2 => const Color(0xFFEA7B0A),
        _ => const Color(0xFF111111),
      };
}
