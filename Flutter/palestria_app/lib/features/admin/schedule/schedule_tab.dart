import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'activation_editor.dart';
import 'slot_type_editor.dart';
import 'template_editor.dart';
import 'time_slot_editor.dart';
import 'override_editor.dart';

/// Gestione completa di tipi lezione, fasce, template, settimane e override.
class ScheduleTab extends ConsumerWidget {
  const ScheduleTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(allSlotTypesProvider);
    final slotsAsync = ref.watch(allTimeSlotsProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(scheduleConfigProvider);
        ref.invalidate(allSlotTypesProvider);
        ref.invalidate(allTimeSlotsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          100,
        ),
        children: [
          const Text('Gestione Orari', style: AppText.pageTitle),
          const SizedBox(height: AppSpacing.lg),
          _typesSection(context, ref, typesAsync),
          _fasceSection(context, ref, slotsAsync),
          const TemplateEditorSection(),
          const ActivationEditorSection(),
          const OverrideEditorSection(),
        ],
      ),
    );
  }

  // ── Tipi di lezione (editabili) ─────────────────────────────────────────────
  Widget _typesSection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Map<String, dynamic>>> typesAsync,
  ) {
    final types = typesAsync.value ?? const [];
    final keys = [for (final t in types) (t['key'] as String?) ?? ''];
    return _section(
      '🏷️ Tipi di lezione',
      trailing: IconButton(
        icon: Icon(
          Icons.add_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        tooltip: 'Nuovo tipo',
        onPressed: () => showSlotTypeEditor(
          context,
          ref,
          existingKeys: keys,
          defaultSort: types.length,
        ),
      ),
      children: [
        if (typesAsync.isLoading && types.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (types.isEmpty)
          const Text(
            'Nessun tipo configurato. Creane uno per iniziare.',
            style: AppText.meta,
          )
        else
          for (final st in types) _typeRow(context, ref, st, keys),
      ],
    );
  }

  Widget _typeRow(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> st,
    List<String> keys,
  ) {
    final active = (st['is_active'] as bool?) ?? true;
    final bookable = (st['bookable'] as bool?) ?? true;
    final price = (st['default_price'] as num?)?.toDouble() ?? 0;
    return Opacity(
      opacity: active ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color:
                    OrgBranding.parseHex(st['color'] as String?) ??
                    AppColors.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          (st['label'] as String?) ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      if (!bookable) _tag('non prenotabile'),
                      if (!active) _tag('disattivo'),
                    ],
                  ),
                  Text(
                    'capienza ${(st['default_capacity'] as num?)?.toInt() ?? 0} · €${price.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Modifica',
              onPressed: () => showSlotTypeEditor(
                context,
                ref,
                existing: st,
                existingKeys: keys,
                defaultSort: 0,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 18,
                color: AppColors.dangerDark,
              ),
              tooltip: 'Elimina',
              onPressed: () => _deleteType(context, ref, st),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteType(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> st,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina tipo'),
        content: Text(
          'Eliminare il tipo "${st['label']}"? Verrà rimosso anche dalle '
          'settimane tipo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.dangerDark,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) throw Exception('Non autorizzato.');
      await repo.deleteSlotType(st['id'] as String);
      ref.invalidate(allSlotTypesProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Tipo eliminato.')));
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Impossibile eliminare (potrebbe essere usato in prenotazioni).',
          ),
        ),
      );
    }
  }

  Widget _tag(String text) => Container(
    margin: const EdgeInsets.only(left: 6),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: AppColors.slateBg,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w700,
        color: AppColors.muted,
      ),
    ),
  );

  // ── Fasce orarie (editabili) ────────────────────────────────────────────────
  Widget _fasceSection(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Map<String, dynamic>>> slotsAsync,
  ) {
    final slots = slotsAsync.value ?? const [];
    return _section(
      '🕐 Fasce orarie',
      trailing: IconButton(
        icon: Icon(
          Icons.add_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
        tooltip: 'Nuova fascia',
        onPressed: () =>
            showTimeSlotEditor(context, ref, defaultSort: slots.length),
      ),
      children: [
        if (slotsAsync.isLoading && slots.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (slots.isEmpty)
          const Text(
            'Nessuna fascia configurata. Aggiungine una.',
            style: AppText.meta,
          )
        else
          for (final ts in slots) _slotRow(context, ref, ts),
      ],
    );
  }

  Widget _slotRow(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> ts,
  ) {
    final active = (ts['is_active'] as bool?) ?? true;
    final range = _slotLabel(ts);
    final label = (ts['label'] as String?) ?? '';
    return Opacity(
      opacity: active ? 1 : 0.5,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.slateBg,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '🕐 $range',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  fontFeatures: AppText.tabularNums,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                label.isEmpty ? '' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.muted),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit, size: 18),
              tooltip: 'Modifica',
              onPressed: () => showTimeSlotEditor(
                context,
                ref,
                existing: ts,
                defaultSort: 0,
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.delete_outline,
                size: 18,
                color: AppColors.dangerDark,
              ),
              tooltip: 'Elimina',
              onPressed: () => _deleteSlot(context, ref, ts),
            ),
          ],
        ),
      ),
    );
  }

  static String _slotLabel(Map<String, dynamic> ts) {
    String hm(String? t) =>
        (t == null || t.length < 5) ? (t ?? '') : t.substring(0, 5);
    return '${hm(ts['start_time'] as String?)} - ${hm(ts['end_time'] as String?)}';
  }

  Future<void> _deleteSlot(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> ts,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina fascia'),
        content: Text(
          'Eliminare la fascia "${_slotLabel(ts)}"? Verrà rimossa dalle '
          'settimane tipo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.dangerDark,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) throw Exception('Non autorizzato.');
      await repo.deleteTimeSlot(ts['id'] as String);
      ref.invalidate(allTimeSlotsProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Fascia eliminata.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Errore eliminazione: $e')),
      );
    }
  }

  Widget _section(
    String title, {
    required List<Widget> children,
    Widget? trailing,
  }) => AppCard(
    margin: const EdgeInsets.only(bottom: AppSpacing.lg),
    radius: AppRadius.cardLg,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: AppText.cardTitle)),
            ?trailing,
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ...children,
      ],
    ),
  );
}
