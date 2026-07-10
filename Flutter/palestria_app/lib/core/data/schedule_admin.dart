import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';

/// Repository di editing per Gestione Orari (admin). CRUD su `slot_types`
/// (fasce e template arrivano dopo). Org-scoped: ogni scrittura filtra `org_id`.
class ScheduleAdminRepository {
  ScheduleAdminRepository(this._client, this.orgId);
  final SupabaseClient _client;
  final String orgId;

  Future<List<Map<String, dynamic>>> fetchSlotTypes() async {
    final rows = await _client
        .from('slot_types')
        .select('*')
        .eq('org_id', orgId)
        .order('sort_order')
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// Crea (id null) o aggiorna un tipo slot. La `key` è generata solo alla
  /// creazione (immutabile dopo), come nel web (`_schedUniqueKey`).
  Future<void> saveSlotType({
    String? id,
    required String label,
    required String color,
    required int capacity,
    required double price,
    required bool bookable,
    required bool active,
    required int sortOrder,
    required List<String> existingKeys,
  }) async {
    final payload = {
      'label': label,
      'color': color,
      'default_capacity': capacity,
      'default_price': price,
      'bookable': bookable,
      'is_active': active,
      'sort_order': sortOrder,
    };
    if (id != null) {
      await _client
          .from('slot_types')
          .update(payload)
          .eq('id', id)
          .eq('org_id', orgId);
    } else {
      await _client.from('slot_types').insert({
        ...payload,
        'key': _uniqueKey(label, existingKeys),
        'org_id': orgId,
      });
    }
  }

  Future<void> deleteSlotType(String id) async {
    await _client.from('slot_types').delete().eq('id', id).eq('org_id', orgId);
  }

  // ── Fasce orarie (time_slots_config) ────────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchTimeSlots() async {
    final rows = await _client
        .from('time_slots_config')
        .select('*')
        .eq('org_id', orgId)
        .order('sort_order')
        .order('start_time')
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// start/end in formato 'HH:MM'.
  Future<void> saveTimeSlot({
    String? id,
    required String start,
    required String end,
    String? label,
    required int sortOrder,
  }) async {
    final payload = {
      'start_time': start,
      'end_time': end,
      'label': (label != null && label.trim().isNotEmpty) ? label.trim() : null,
      'sort_order': sortOrder,
    };
    if (id != null) {
      await _client
          .from('time_slots_config')
          .update(payload)
          .eq('id', id)
          .eq('org_id', orgId);
    } else {
      await _client.from('time_slots_config').insert({
        ...payload,
        'is_active': true,
        'org_id': orgId,
      });
    }
  }

  Future<void> deleteTimeSlot(String id) async {
    await _client
        .from('time_slots_config')
        .delete()
        .eq('id', id)
        .eq('org_id', orgId);
  }

  // ── Settimana tipo (weekly_schedule_templates + weekly_template_slots) ───────
  Future<List<Map<String, dynamic>>> fetchTemplates() async {
    final rows = await _client
        .from('weekly_schedule_templates')
        .select('id,name,is_active')
        .eq('org_id', orgId)
        .order('name')
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  Future<List<Map<String, dynamic>>> fetchTemplateSlots(
    String templateId,
  ) async {
    final rows = await _client
        .from('weekly_template_slots')
        .select('id,weekday,time_slot_id,slot_type_id,capacity')
        .eq('org_id', orgId)
        .eq('template_id', templateId)
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// Crea un template; ritorna l'id. `isFirst` → is_active=true.
  Future<String> createTemplate(String name, bool isFirst) async {
    final row = await _client
        .from('weekly_schedule_templates')
        .insert({'org_id': orgId, 'name': name, 'is_active': isFirst})
        .select('id')
        .single();
    return row['id'] as String;
  }

  Future<void> renameTemplate(String id, String name) async {
    await _client
        .from('weekly_schedule_templates')
        .update({'name': name})
        .eq('id', id)
        .eq('org_id', orgId);
  }

  Future<void> deleteTemplate(String id) async {
    // weekly_template_slots ha ON DELETE CASCADE sul template.
    await _client
        .from('weekly_schedule_templates')
        .delete()
        .eq('id', id)
        .eq('org_id', orgId);
  }

  /// Imposta il tipo di una cella (upsert/delete riga weekly_template_slots).
  /// slotTypeId null/'' → rimuove la cella. Al set/cambio tipo resetta la
  /// capienza (eredita la default del tipo). [existingId] = riga già presente.
  Future<void> setCell({
    required String templateId,
    required int weekday,
    required String timeSlotId,
    required String? slotTypeId,
    int? capacity,
    String? existingId,
  }) async {
    if (slotTypeId == null || slotTypeId.isEmpty) {
      if (existingId != null) {
        await _client
            .from('weekly_template_slots')
            .delete()
            .eq('id', existingId)
            .eq('org_id', orgId);
      }
      return;
    }
    if (existingId != null) {
      await _client
          .from('weekly_template_slots')
          .update({'slot_type_id': slotTypeId, 'capacity': capacity})
          .eq('id', existingId)
          .eq('org_id', orgId);
    } else {
      await _client.from('weekly_template_slots').insert({
        'org_id': orgId,
        'template_id': templateId,
        'weekday': weekday,
        'time_slot_id': timeSlotId,
        'slot_type_id': slotTypeId,
        'capacity': capacity,
      });
    }
  }

  /// Aggiorna solo la capienza di una cella esistente (null = default del tipo).
  Future<void> setCellCapacity(String existingId, int? capacity) async {
    await _client
        .from('weekly_template_slots')
        .update({'capacity': capacity})
        .eq('id', existingId)
        .eq('org_id', orgId);
  }

  // ── Attiva settimane (activated_weeks) ──────────────────────────────────────
  Future<List<Map<String, dynamic>>> fetchActivatedWeeks() async {
    final rows = await _client
        .from('activated_weeks')
        .select('week_start,template_id')
        .eq('org_id', orgId)
        .order('week_start')
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  Future<void> activateWeek(String weekStart, String templateId) async {
    await _client.from('activated_weeks').upsert({
      'org_id': orgId,
      'week_start': weekStart,
      'template_id': templateId,
    }, onConflict: 'org_id,week_start');
  }

  Future<void> deactivateWeek(String weekStart) async {
    await _client
        .from('activated_weeks')
        .delete()
        .eq('org_id', orgId)
        .eq('week_start', weekStart);
  }

  /// True se la settimana [lunedì..domenica] ha ≥1 prenotazione non cancellata.
  /// Fail-safe: in errore ritorna true (meglio bloccare la modifica).
  Future<bool> weekHasBookings(String weekStart) async {
    final parts = weekStart.split('-').map(int.parse).toList();
    final end = DateTime(
      parts[0],
      parts[1],
      parts[2],
    ).add(const Duration(days: 6));
    final weekEnd =
        '${end.year.toString().padLeft(4, '0')}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}';
    try {
      final rows = await _client
          .from('bookings')
          .select('id')
          .eq('org_id', orgId)
          .neq('status', 'cancelled')
          .gte('date', weekStart)
          .lte('date', weekEnd)
          .limit(1)
          .timeout(const Duration(seconds: 12));
      return rows.isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  static String _slugify(String s) {
    var out = s.toLowerCase().trim();
    const map = {
      'à': 'a',
      'á': 'a',
      'â': 'a',
      'è': 'e',
      'é': 'e',
      'ì': 'i',
      'í': 'i',
      'ò': 'o',
      'ó': 'o',
      'ù': 'u',
      'ú': 'u',
    };
    map.forEach((k, v) => out = out.replaceAll(k, v));
    out = out.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    out = out.replaceAll(RegExp(r'^-+|-+$'), '');
    return out;
  }

  static String _uniqueKey(String label, List<String> existing) {
    final base = _slugify(label).isEmpty ? 'slot' : _slugify(label);
    final set = existing.toSet();
    var key = base;
    var i = 2;
    while (set.contains(key)) {
      key = '$base-${i++}';
    }
    return key;
  }
}

final scheduleAdminRepoProvider = FutureProvider<ScheduleAdminRepository?>((
  ref,
) async {
  final ctx = await ref.watch(orgContextProvider.future);
  if (ctx.orgId == null || !ctx.isOrgAdmin) return null;
  return ScheduleAdminRepository(ref.watch(supabaseProvider), ctx.orgId!);
});

/// Tutti i tipi slot della org (inclusi inattivi) per l'editor.
final allSlotTypesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(scheduleAdminRepoProvider.future);
  if (repo == null) return const [];
  return repo.fetchSlotTypes();
});

/// Tutte le fasce orarie della org (incluse inattive) per l'editor.
final allTimeSlotsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(scheduleAdminRepoProvider.future);
  if (repo == null) return const [];
  return repo.fetchTimeSlots();
});

/// Template settimana tipo della org.
final allTemplatesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(scheduleAdminRepoProvider.future);
  if (repo == null) return const [];
  return repo.fetchTemplates();
});

/// Celle di un template (weekly_template_slots).
final templateSlotsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      templateId,
    ) async {
      final repo = await ref.watch(scheduleAdminRepoProvider.future);
      if (repo == null) return const [];
      return repo.fetchTemplateSlots(templateId);
    });

/// Settimane attivate della org.
final activatedWeeksProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(scheduleAdminRepoProvider.future);
  if (repo == null) return const [];
  return repo.fetchActivatedWeeks();
});
