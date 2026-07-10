import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../../core/theme/org_theme.dart';
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
      return const AppLoading();
    }
    if (configAsync.hasError || overridesAsync.hasError) {
      return AppErrorRetry(
        onRetry: () {
          ref.invalidate(scheduleConfigProvider);
          ref.invalidate(scheduleOverridesProvider);
        },
      );
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
          _bookingHero(
              days, selectedDay, dayHasAvailable, own, primary, weekHasSlots),
          const SizedBox(height: AppSpacing.lg),
          if (daySlots.isEmpty)
            AppEmptyState(
              title: hadSlots
                  ? 'Nessuna lezione disponibile per questo giorno'
                  : 'Nessuna lezione programmata per questo giorno',
            )
          else
            ...daySlots.map((s) => _slotCard(context, config, s)),
          const SizedBox(height: AppSpacing.xxxl),
        ],
      ),
    );
  }

  /// Hero della sezione Prenotazioni (stesso stile dell'hero admin): nome
  /// palestra/PT + navigazione settimana con frecce "glass" + i 7 giorni come
  /// chip glass, tutto sul gradiente scuro→viola con glow org-aware.
  Widget _bookingHero(
    List<DateTime> days,
    DateTime selectedDay,
    bool Function(DateTime) dayHasAvailable,
    List<dynamic> own,
    Color primary,
    bool Function(int) weekHasSlots,
  ) {
    final name = ref.watch(orgBrandingProvider).studioName?.trim();
    final range =
        '${days.first.day} ${kMonthShort[days.first.month - 1]} — ${days.last.day} ${kMonthShort[days.last.month - 1]}';
    final prevEnabled = _weekOffset > 0;
    final nextEnabled = weekHasSlots(_weekOffset + 1);

    return DarkHero(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          // Riga brand: icona + eyebrow + nome studio
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.event_available_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('PRENOTA LA TUA LEZIONE',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                            color: Colors.white.withValues(alpha: 0.7))),
                    const SizedBox(height: 3),
                    Text(
                      (name != null && name.isNotEmpty) ? name : 'Prenotazioni',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: -0.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          // Navigazione settimana con frecce glass (etichetta: solo anno)
          Row(
            children: [
              _navBtn(Icons.chevron_left, prevEnabled, () {
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
                    Text('${days.first.year}',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                            color: Colors.white.withValues(alpha: 0.72))),
                  ],
                ),
              ),
              _navBtn(Icons.chevron_right, nextEnabled, () {
                setState(() {
                  _weekOffset++;
                  _selectedDay = null;
                });
              }),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _daySelector(
              days, selectedDay, dayHasAvailable, own, primary, weekHasSlots),
        ],
      ),
    );
  }

  Widget _navBtn(IconData icon, bool enabled, VoidCallback onTap) => Opacity(
        opacity: enabled ? 1 : 0.3,
        child: IconButton(
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, color: Colors.white),
          style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.12)),
        ),
      );

  Widget _daySelector(
    List<DateTime> days,
    DateTime selected,
    bool Function(DateTime) dayHasAvailable,
    List<dynamic> own,
    Color primary,
    bool Function(int) weekHasSlots,
  ) {
    bool hasEnrollment(DateTime d) {
      final ds = OrgScheduleConfig.localDateStr(d);
      return own.any((b) => b.date == ds && b.isOccupying == true);
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -200 && weekHasSlots(_weekOffset + 1)) {
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
    // Chip "glass" sull'hero scuro: default translucido bianco; active =
    // gradiente pieno (rosso se già iscritto); enrolled = tinta rossa; disabled 0.35.
    Gradient? gradient;
    Color bg = Colors.white.withValues(alpha: 0.08);
    Color border = Colors.white.withValues(alpha: 0.16);
    Color fg = Colors.white.withValues(alpha: 0.78);

    if (isActive && enrolled) {
      gradient = const LinearGradient(
          colors: [AppColors.danger, AppColors.dangerDark]);
      fg = Colors.white;
    } else if (isActive) {
      gradient = LinearGradient(colors: [
        primary,
        Color.fromARGB(255, ((primary.r * 255) * 0.9).round(),
            ((primary.g * 255) * 0.9).round(), ((primary.b * 255) * 0.9).round())
      ]);
      fg = Colors.white;
    } else if (enrolled) {
      bg = AppColors.danger.withValues(alpha: 0.30);
      border = AppColors.danger.withValues(alpha: 0.55);
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
            color: spotsColor(slot.remaining),
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
            boxShadow: AppShadows.card,
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
}
