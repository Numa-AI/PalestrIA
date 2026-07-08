import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/booking_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';

/// Nomi italiani (identici al web).
const kDayNames = [
  'Domenica', 'Lunedì', 'Martedì', 'Mercoledì', 'Giovedì', 'Venerdì', 'Sabato'
];
const kDayShort = ['Dom', 'Lun', 'Mar', 'Mer', 'Gio', 'Ven', 'Sab'];
const kMonthShort = [
  'Gen', 'Feb', 'Mar', 'Apr', 'Mag', 'Giu',
  'Lug', 'Ago', 'Set', 'Ott', 'Nov', 'Dic'
];
const kMonthNames = [
  'Gennaio', 'Febbraio', 'Marzo', 'Aprile', 'Maggio', 'Giugno',
  'Luglio', 'Agosto', 'Settembre', 'Ottobre', 'Novembre', 'Dicembre'
];

/// "GiornoNome D/M" (es. "Sabato 4/7") — formato dateDisplay del web.
String dateDisplayOf(DateTime d) =>
    '${kDayNames[d.weekday % 7]} ${d.day}/${d.month}';

/// "Sabato 4 Luglio 2026" — formato card prenotazione.
String longDateOf(DateTime d) =>
    '${kDayNames[d.weekday % 7]} ${d.day} ${kMonthNames[d.month - 1]} ${d.year}';

DateTime parseYmd(String ymd) => DateTime.parse(ymd);

/// Inizio lezione come DateTime locale (date 'YYYY-MM-DD' + time 'HH:MM - HH:MM').
DateTime lessonStart(String date, String time) {
  final d = parseYmd(date);
  final hm = time.split(' - ').first.split(':');
  return DateTime(d.year, d.month, d.day, int.parse(hm[0]), int.parse(hm[1]));
}

/// Override puntuale di calendario (tabella `schedule_overrides`).
class ScheduleOverride {
  const ScheduleOverride({
    required this.date,
    required this.time,
    required this.slotType,
    this.capacity,
  });

  final String date;
  final String time;
  final String slotType;

  /// Capienza ASSOLUTA (null = default del tipo).
  final int? capacity;
}

/// Overrides finestrati (oggi−30gg in poi, cutoff non-admin come il web).
final scheduleOverridesProvider =
    FutureProvider<Map<String, List<ScheduleOverride>>>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  if (orgContext.orgId == null) return const {};
  final cutoff = OrgScheduleConfig.localDateStr(
      DateTime.now().subtract(const Duration(days: 30)));
  final rows = await ref
      .read(supabaseProvider)
      .from('schedule_overrides')
      .select('date, time, slot_type, capacity')
      .eq('org_id', orgContext.orgId!)
      .gte('date', cutoff)
      .timeout(const Duration(seconds: 12));
  final map = <String, List<ScheduleOverride>>{};
  for (final r in rows) {
    final o = ScheduleOverride(
      date: r['date'] as String,
      time: r['time'] as String,
      slotType: (r['slot_type'] as String?) ?? '',
      capacity: (r['capacity'] as num?)?.toInt(),
    );
    map.putIfAbsent(o.date, () => []).add(o);
  }
  return map;
});

/// Prenotazioni dell'utente corrente (refresh: ref.invalidate).
final ownBookingsProvider = FutureProvider<List<Booking>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  final repo = await ref.watch(bookingRepositoryProvider.future);
  return repo.fetchOwnBookings(session.user.id);
});

/// Disponibilità server (oggi → +90 gg), indicizzata per 'date|time|type'.
final availabilityProvider =
    FutureProvider<Map<String, SlotAvailability>>((ref) async {
  final repo = await ref.watch(bookingRepositoryProvider.future);
  final now = DateTime.now();
  final list =
      await repo.fetchAvailability(now, now.add(const Duration(days: 90)));
  return {for (final a in list) a.key: a};
});

/// Slot visualizzabile di un giorno (già risolto tra template/override).
class DaySlot {
  const DaySlot({
    required this.date,
    required this.time,
    required this.slotType,
    required this.capacity,
    required this.remaining,
    required this.enrolled,
    required this.bookable,
  });

  final String date;
  final String time;
  final String slotType;
  final int capacity;
  final int remaining;

  /// true se l'utente corrente è iscritto a questo slot.
  final bool enrolled;

  /// tipo prenotabile (slot_types.bookable; cleaning/non prenotabili esclusi).
  final bool bookable;

  bool get isFull => remaining <= 0;

  /// Cutoff web: prenotabile/visibile finché non sono passati 30 min
  /// dall'inizio della lezione.
  bool get pastCutoff =>
      DateTime.now().isAfter(
          lessonStart(date, time).add(const Duration(minutes: 30)));
}

/// Calcola gli slot di un giorno: override puntuale → template settimana
/// attivata → niente. Posti: server-authoritative se disponibile.
List<DaySlot> computeDaySlots({
  required DateTime day,
  required OrgScheduleConfig config,
  required Map<String, List<ScheduleOverride>> overrides,
  required Map<String, SlotAvailability> availability,
  required List<Booking> ownBookings,
}) {
  final dateStr = OrgScheduleConfig.localDateStr(day);

  // (time, type) → capacity
  final entries = <(String, String, int)>[];
  final dayOverrides = overrides[dateStr];
  if (dayOverrides != null && dayOverrides.isNotEmpty) {
    for (final o in dayOverrides) {
      final cap =
          o.capacity ?? config.slotTypes[o.slotType]?.defaultCapacity ?? 0;
      entries.add((o.time, o.slotType, cap));
    }
    // Slot del template non coperti da override restano visibili.
    config.daySchedule(day).forEach((time, slot) {
      if (!dayOverrides.any((o) => o.time == time)) {
        entries.add((time, slot.slotTypeKey, slot.capacity));
      }
    });
  } else {
    config.daySchedule(day).forEach((time, slot) {
      entries.add((time, slot.slotTypeKey, slot.capacity));
    });
  }

  entries.sort((a, b) => a.$1.compareTo(b.$1));

  return [
    for (final (time, type, capacity) in entries)
      () {
        final avail = availability['$dateStr|$time|$type'];
        final enrolled = ownBookings.any((b) =>
            b.date == dateStr &&
            b.time == time &&
            b.isOccupying);
        return DaySlot(
          date: dateStr,
          time: time,
          slotType: type,
          capacity: avail?.capacity ?? capacity,
          remaining: avail?.remaining ?? capacity,
          enrolled: enrolled,
          bookable: config.slotTypes[type]?.bookable ??
              !(type == 'group-class' || type == 'cleaning'),
        );
      }(),
  ];
}
