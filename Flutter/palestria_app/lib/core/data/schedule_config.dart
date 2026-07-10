import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../models/slot_type.dart';

/// Slot di un template settimanale risolto (weekday+time → tipo e capienza).
class TemplateSlot {
  const TemplateSlot({
    required this.slotTypeId,
    required this.slotTypeKey,
    required this.capacity,
  });

  final String slotTypeId;
  final String slotTypeKey;
  final int capacity;

  Map<String, dynamic> toJson() => {
    'slotTypeId': slotTypeId,
    'slotTypeKey': slotTypeKey,
    'capacity': capacity,
  };

  static TemplateSlot fromJson(Map<String, dynamic> json) => TemplateSlot(
    slotTypeId: json['slotTypeId'] as String,
    slotTypeKey: json['slotTypeKey'] as String,
    capacity: (json['capacity'] as num).toInt(),
  );
}

/// Config orari per-org (port di loadOrgScheduleConfig, spec-data §5.2):
/// slot_types, fasce orarie, settimane attivate e template settimanali.
/// Con snapshot sincrono anti-flash in SharedPreferences (`_orgSchedSnap_<orgId>`).
class OrgScheduleConfig {
  OrgScheduleConfig({
    required this.slotTypes,
    required this.timeSlots,
    required this.activeWeeks,
    required this.weeklyTemplates,
  });

  /// key → SlotType (solo attivi, ordinati per sort_order)
  final Map<String, SlotType> slotTypes;

  /// etichette 'HH:MM - HH:MM' attive ordinate
  final List<String> timeSlots;

  /// lunedì ISO 'YYYY-MM-DD' → templateId (settimana non presente = non prenotabile)
  final Map<String, String> activeWeeks;

  /// templateId → weekday(0=Domenica..6) → time → TemplateSlot
  final Map<String, Map<int, Map<String, TemplateSlot>>> weeklyTemplates;

  static OrgScheduleConfig empty() => OrgScheduleConfig(
    slotTypes: {},
    timeSlots: [],
    activeWeeks: {},
    weeklyTemplates: {},
  );

  String slotName(String key) => slotTypes[key]?.label ?? key;

  Color slotColor(String key) =>
      slotTypes[key]?.color ?? const Color(0xFF8B5CF6);

  /// Lunedì ISO della settimana di [date] (allineato a date_trunc('week')).
  static String mondayYmd(DateTime date) {
    final monday = date.subtract(Duration(days: date.weekday - 1));
    return localDateStr(monday);
  }

  /// `YYYY-MM-DD` in fuso LOCALE (mai UTC: off-by-one dopo le 23 CET).
  static String localDateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Griglia del giorno: time → TemplateSlot, dal template della settimana
  /// ATTIVATA. Settimana non attivata → griglia vuota (mai default legacy).
  Map<String, TemplateSlot> daySchedule(DateTime date) {
    final templateId = activeWeeks[mondayYmd(date)];
    if (templateId == null) return const {};
    final weekday = date.weekday % 7; // DateTime: 1=lun..7=dom → 0=domenica
    return weeklyTemplates[templateId]?[weekday] ?? const {};
  }

  Map<String, dynamic> toJson() => {
    'slotTypes': slotTypes.map((k, v) => MapEntry(k, v.toJson())),
    'timeSlots': timeSlots,
    'activeWeeks': activeWeeks,
    'weeklyTemplates': weeklyTemplates.map(
      (tpl, days) => MapEntry(
        tpl,
        days.map(
          (d, slots) => MapEntry(
            d.toString(),
            slots.map((t, s) => MapEntry(t, s.toJson())),
          ),
        ),
      ),
    ),
  };

  static OrgScheduleConfig fromJson(Map<String, dynamic> json) =>
      OrgScheduleConfig(
        slotTypes: (json['slotTypes'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, SlotType.fromRow(v as Map<String, dynamic>)),
        ),
        timeSlots: (json['timeSlots'] as List).cast<String>(),
        activeWeeks: (json['activeWeeks'] as Map<String, dynamic>)
            .cast<String, String>(),
        weeklyTemplates: (json['weeklyTemplates'] as Map<String, dynamic>).map(
          (tpl, days) => MapEntry(
            tpl,
            (days as Map<String, dynamic>).map(
              (d, slots) => MapEntry(
                int.parse(d),
                (slots as Map<String, dynamic>).map(
                  (t, s) => MapEntry(
                    t,
                    TemplateSlot.fromJson(s as Map<String, dynamic>),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class ScheduleConfigRepository {
  ScheduleConfigRepository(this._client, this.orgId, this._prefs);

  final SupabaseClient _client;
  final String orgId;
  final SharedPreferences _prefs;

  String get _snapKey => '_orgSchedSnap_$orgId';

  /// Idratazione sincrona dallo snapshot (anti-flash), come nel web.
  OrgScheduleConfig? hydrateFromCache() {
    final raw = _prefs.getString(_snapKey);
    if (raw == null) return null;
    try {
      return OrgScheduleConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Carica le 4 strutture in parallelo e persiste lo snapshot.
  Future<OrgScheduleConfig> load() async {
    final results = await Future.wait<dynamic>([
      _client
          .from('slot_types')
          .select()
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('sort_order'),
      _client
          .from('time_slots_config')
          .select('start_time, end_time, is_active, sort_order')
          .eq('org_id', orgId)
          .eq('is_active', true)
          .order('sort_order'),
      _client
          .from('activated_weeks')
          .select('week_start, template_id')
          .eq('org_id', orgId),
      _client
          .from('weekly_template_slots')
          .select(
            'template_id, weekday, capacity, slot_type_id, '
            'time_slots_config(start_time, end_time), '
            'slot_types(id, key, default_capacity)',
          )
          .eq('org_id', orgId),
    ]).timeout(const Duration(seconds: 12));

    final slotTypes = <String, SlotType>{};
    for (final row in results[0] as List) {
      final st = SlotType.fromRow(row as Map<String, dynamic>);
      slotTypes[st.key] = st;
    }

    String label(Map<String, dynamic> ts) {
      String hm(String t) => t.substring(0, 5);
      return '${hm(ts['start_time'] as String)} - ${hm(ts['end_time'] as String)}';
    }

    final timeSlots = [
      for (final row in results[1] as List) label(row as Map<String, dynamic>),
    ];

    final activeWeeks = <String, String>{
      for (final row in results[2] as List)
        (row['week_start'] as String): (row['template_id'] as String),
    };

    final weeklyTemplates = <String, Map<int, Map<String, TemplateSlot>>>{};
    for (final raw in results[3] as List) {
      final row = raw as Map<String, dynamic>;
      final ts = row['time_slots_config'] as Map<String, dynamic>?;
      final st = row['slot_types'] as Map<String, dynamic>?;
      if (ts == null || st == null) continue;
      final tplId = row['template_id'] as String;
      final weekday = (row['weekday'] as num).toInt();
      final time = label(ts);
      final capacity =
          (row['capacity'] as num?)?.toInt() ??
          (st['default_capacity'] as num?)?.toInt() ??
          1;
      weeklyTemplates
          .putIfAbsent(tplId, () => {})
          .putIfAbsent(weekday, () => {})[time] = TemplateSlot(
        slotTypeId: st['id'] as String,
        slotTypeKey: st['key'] as String,
        capacity: capacity,
      );
    }

    final config = OrgScheduleConfig(
      slotTypes: slotTypes,
      timeSlots: timeSlots,
      activeWeeks: activeWeeks,
      weeklyTemplates: weeklyTemplates,
    );
    await _prefs.setString(_snapKey, jsonEncode(config.toJson()));
    return config;
  }
}

/// Config orari della org corrente: prima lo snapshot locale (subito),
/// poi il refresh dal server.
final scheduleConfigProvider = FutureProvider<OrgScheduleConfig>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  final orgId = orgContext.orgId;
  if (orgId == null) return OrgScheduleConfig.empty();

  final prefs = await SharedPreferences.getInstance();
  final repo = ScheduleConfigRepository(
    ref.watch(supabaseProvider),
    orgId,
    prefs,
  );
  try {
    return await repo.load();
  } catch (_) {
    // offline/errore: si usa lo snapshot se esiste
    return repo.hydrateFromCache() ?? OrgScheduleConfig.empty();
  }
});
