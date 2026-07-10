import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';

final scheduleOverridesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, date) async {
      final context = await ref.watch(orgContextProvider.future);
      if (context.orgId == null || !context.isOrgAdmin) return const [];
      final rows = await ref
          .watch(supabaseProvider)
          .from('schedule_overrides')
          .select('id,date,time,slot_type,slot_type_id,capacity')
          .eq('org_id', context.orgId!)
          .eq('date', date)
          .order('time')
          .timeout(const Duration(seconds: 15));
      return [for (final row in rows) (row as Map).cast<String, dynamic>()];
    });

class OverrideEditorSection extends ConsumerStatefulWidget {
  const OverrideEditorSection({super.key});

  @override
  ConsumerState<OverrideEditorSection> createState() =>
      _OverrideEditorSectionState();
}

class _OverrideEditorSectionState extends ConsumerState<OverrideEditorSection> {
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day);
  }

  String get _ymd => OrgScheduleConfig.localDateStr(_date);

  @override
  Widget build(BuildContext context) {
    final overridesAsync = ref.watch(scheduleOverridesProvider(_ymd));
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    final types =
        ref.watch(allSlotTypesProvider).value ?? const <Map<String, dynamic>>[];
    final timeRows =
        ref.watch(allTimeSlotsProvider).value ?? const <Map<String, dynamic>>[];
    final bookings = ref.watch(adminBookingsProvider).value ?? const [];
    final times = [
      for (final row in timeRows.where((r) => r['is_active'] != false))
        _timeLabel(row),
    ];
    final overrideRows = overridesAsync.value ?? const <Map<String, dynamic>>[];
    final byTime = {for (final row in overrideRows) row['time'] as String: row};
    final base = config.daySchedule(_date);
    final orphans = overrideRows
        .where((row) => !times.contains(row['time']))
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.borderGray),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _header(context),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              children: [
                _datePicker(context),
                const SizedBox(height: AppSpacing.md),
                if (overridesAsync.isLoading)
                  const LinearProgressIndicator(minHeight: 2)
                else if (times.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Configura prima almeno una fascia oraria.'),
                  )
                else
                  for (final time in times)
                    _slotRow(
                      context,
                      time: time,
                      baseSlot: base[time],
                      override: byTime[time],
                      occupied: bookings
                          .where(
                            (b) =>
                                b.date == _ymd &&
                                b.time == time &&
                                b.status != 'cancelled',
                          )
                          .length,
                      types: types,
                    ),
                if (orphans.isNotEmpty) ...[
                  const Divider(height: 28),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Override orfani',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: AppColors.amber,
                      ),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'La fascia originale è stata rinominata o rimossa.',
                      style: TextStyle(fontSize: 11.5, color: AppColors.muted),
                    ),
                  ),
                  for (final row in orphans) _orphanRow(context, row),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFF312E81), Color(0xFF6D28D9)]),
    ),
    child: const Row(
      children: [
        Icon(Icons.tune, color: Colors.white),
        SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Override giornalieri',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                'Modifica tipo o capienza senza alterare la settimana tipo',
                style: TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _datePicker(BuildContext context) => Row(
    children: [
      IconButton.filledTonal(
        onPressed: () =>
            setState(() => _date = _date.subtract(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_left),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: InkWell(
          onTap: () async {
            final value = await showDatePicker(
              context: context,
              initialDate: _date,
              firstDate: DateTime(2020),
              lastDate: DateTime(DateTime.now().year + 5),
            );
            if (value != null) setState(() => _date = value);
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F3FF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.event_outlined,
                  size: 19,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  '${_weekday(_date.weekday)} ${_date.day} ${_month(_date.month)} ${_date.year}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        onPressed: () =>
            setState(() => _date = _date.add(const Duration(days: 1))),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );

  Widget _slotRow(
    BuildContext context, {
    required String time,
    required TemplateSlot? baseSlot,
    required Map<String, dynamic>? override,
    required int occupied,
    required List<Map<String, dynamic>> types,
  }) {
    final typeId = override?['slot_type_id'] as String? ?? baseSlot?.slotTypeId;
    final type = types.where((t) => t['id'] == typeId).firstOrNull;
    final capacity =
        (override?['capacity'] as num?)?.toInt() ?? baseSlot?.capacity ?? 0;
    final color =
        OrgBranding.parseHex(type?['color'] as String?) ?? AppColors.primary;
    final custom = override != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: custom ? color.withValues(alpha: .055) : const Color(0xFFFAFAFC),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: custom ? color.withValues(alpha: .32) : AppColors.borderGray,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 42,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      time,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    if (custom) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          'OVERRIDE',
                          style: TextStyle(
                            fontSize: 8,
                            fontWeight: FontWeight.w900,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  type?['label'] as String? ??
                      (baseSlot == null
                          ? 'Slot non attivo'
                          : baseSlot.slotTypeKey),
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ],
            ),
          ),
          _capacityBadge(occupied, capacity),
          const SizedBox(width: 6),
          IconButton.filledTonal(
            tooltip: custom ? 'Modifica override' : 'Crea override',
            onPressed: () =>
                _edit(context, time, typeId, capacity, occupied, types),
            icon: Icon(custom ? Icons.edit_outlined : Icons.add),
          ),
          if (custom)
            IconButton(
              tooltip: 'Ripristina settimana tipo',
              onPressed: () => _delete(context, time),
              icon: const Icon(Icons.restore, color: AppColors.dangerDark),
            ),
        ],
      ),
    );
  }

  Widget _capacityBadge(int occupied, int capacity) {
    final full = capacity > 0 && occupied >= capacity;
    final invalid = occupied > capacity;
    final color = invalid || full ? AppColors.dangerDark : AppColors.green600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        '$occupied / $capacity',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 12,
          color: color,
        ),
      ),
    );
  }

  Widget _orphanRow(BuildContext context, Map<String, dynamic> row) => ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.link_off, color: AppColors.amber),
    title: Text(row['time'] as String? ?? '—'),
    subtitle: Text(
      '${row['slot_type'] ?? 'tipo sconosciuto'} · capienza ${row['capacity'] ?? 0}',
    ),
    trailing: IconButton(
      icon: const Icon(Icons.delete_outline, color: AppColors.dangerDark),
      onPressed: () => _delete(context, row['time'] as String),
    ),
  );

  Future<void> _edit(
    BuildContext context,
    String time,
    String? initialType,
    int initialCapacity,
    int occupied,
    List<Map<String, dynamic>> types,
  ) async {
    var selectedType =
        initialType ?? (types.isEmpty ? null : types.first['id'] as String?);
    var capacity = initialCapacity < occupied ? occupied : initialCapacity;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$time · $_ymd',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Text(
                  'La capienza non può scendere sotto le prenotazioni già presenti.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
                const SizedBox(height: AppSpacing.lg),
                DropdownButtonFormField<String>(
                  initialValue: selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Tipo di lezione',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final t in types.where((t) => t['is_active'] != false))
                      DropdownMenuItem(
                        value: t['id'] as String,
                        child: Text(t['label'] as String? ?? ''),
                      ),
                  ],
                  onChanged: (v) => setSheetState(() => selectedType = v),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: capacity <= occupied
                          ? null
                          : () => setSheetState(() => capacity--),
                      icon: const Icon(Icons.remove),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            '$capacity',
                            style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            '$occupied già prenotat${occupied == 1 ? 'o' : 'i'}',
                            style: const TextStyle(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filled(
                      onPressed: () => setSheetState(() => capacity++),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: selectedType == null
                      ? null
                      : () => Navigator.pop(sheetContext, true),
                  child: const Text('Salva override'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || selectedType == null) return;
    try {
      await ref
          .read(supabaseProvider)
          .rpc(
            'admin_upsert_schedule_override',
            params: {
              'p_date': _ymd,
              'p_time': time,
              'p_slot_type_id': selectedType,
              'p_capacity': capacity,
            },
          )
          .timeout(const Duration(seconds: 20));
      ref.invalidate(scheduleOverridesProvider(_ymd));
      ref.invalidate(scheduleConfigProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage(e)),
            backgroundColor: AppColors.dangerDark,
          ),
        );
      }
    }
  }

  Future<void> _delete(BuildContext context, String time) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Ripristina settimana tipo'),
            content: Text('Rimuovere l’override di $time per $_ymd?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Annulla'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ripristina'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    try {
      await ref
          .read(supabaseProvider)
          .rpc(
            'admin_delete_schedule_override',
            params: {'p_date': _ymd, 'p_time': time},
          )
          .timeout(const Duration(seconds: 20));
      ref.invalidate(scheduleOverridesProvider(_ymd));
      ref.invalidate(scheduleConfigProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_errorMessage(e)),
            backgroundColor: AppColors.dangerDark,
          ),
        );
      }
    }
  }

  static String _timeLabel(Map<String, dynamic> row) {
    String hm(Object? value) => value.toString().substring(0, 5);
    return '${hm(row['start_time'])} - ${hm(row['end_time'])}';
  }

  static String _errorMessage(Object error) {
    final text = error.toString();
    if (text.contains('capacity_below_occupancy')) {
      return 'Capienza inferiore alle prenotazioni presenti.';
    }
    if (text.contains('override_type_conflicts_with_bookings')) {
      return 'Non puoi cambiare tipo: lo slot contiene prenotazioni di un altro tipo.';
    }
    if (text.contains('fallback_cannot_hold_bookings')) {
      return 'La settimana tipo non può contenere le prenotazioni presenti.';
    }
    return 'Operazione non riuscita: $text';
  }

  static String _weekday(int value) => const [
    '',
    'Lunedì',
    'Martedì',
    'Mercoledì',
    'Giovedì',
    'Venerdì',
    'Sabato',
    'Domenica',
  ][value];
  static String _month(int value) => const [
    '',
    'gennaio',
    'febbraio',
    'marzo',
    'aprile',
    'maggio',
    'giugno',
    'luglio',
    'agosto',
    'settembre',
    'ottobre',
    'novembre',
    'dicembre',
  ][value];
}
