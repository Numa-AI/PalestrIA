import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

const _weekdayOrder = [1, 2, 3, 4, 5, 6, 0];
const _weekdayShort = {
  1: 'Lun', 2: 'Mar', 3: 'Mer', 4: 'Gio', 5: 'Ven', 6: 'Sab', 0: 'Dom'
};

/// Editor "Settimana tipo" (port di _schedRenderTemplate §Editor3): template
/// riutilizzabili + griglia giorno×fascia (qui: tab-giorno + righe fascia con
/// tipo di slot e capienza). Adattato a mobile (niente tabella 7 colonne).
class TemplateEditorSection extends ConsumerStatefulWidget {
  const TemplateEditorSection({super.key});

  @override
  ConsumerState<TemplateEditorSection> createState() =>
      _TemplateEditorSectionState();
}

class _TemplateEditorSectionState
    extends ConsumerState<TemplateEditorSection> {
  String? _templateId;
  int _weekday = 1;

  @override
  Widget build(BuildContext context) {
    final templatesAsync = ref.watch(allTemplatesProvider);
    final typesAsync = ref.watch(allSlotTypesProvider);
    final slotsAsync = ref.watch(allTimeSlotsProvider);
    final templates = templatesAsync.value ?? const [];
    final types = (typesAsync.value ?? const [])
        .where((t) => (t['is_active'] as bool?) ?? true)
        .toList();
    final slots = (slotsAsync.value ?? const [])
        .where((t) => (t['is_active'] as bool?) ?? true)
        .toList();
    final loading = (templatesAsync.isLoading && templates.isEmpty) ||
        (typesAsync.isLoading && types.isEmpty) ||
        (slotsAsync.isLoading && slots.isEmpty);
    final hasError =
        templatesAsync.hasError || typesAsync.hasError || slotsAsync.hasError;

    // Seleziona il primo template se nessuno scelto.
    var tid = _templateId;
    if (tid == null && templates.isNotEmpty) {
      tid = templates.first['id'] as String;
    } else if (tid != null && !templates.any((t) => t['id'] == tid)) {
      tid = templates.isEmpty ? null : templates.first['id'] as String;
    }

    Widget body;
    if (loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: AppLoading(),
      );
    } else if (hasError) {
      body = AppErrorRetry(
        onRetry: () {
          ref.invalidate(allTemplatesProvider);
          ref.invalidate(allSlotTypesProvider);
          ref.invalidate(allTimeSlotsProvider);
        },
      );
    } else if (templates.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text('Nessuna settimana tipo. Creane una per iniziare.',
            style: AppText.meta),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: tid,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Settimana', isDense: true),
                  items: [
                    for (final t in templates)
                      DropdownMenuItem(
                          value: t['id'] as String,
                          child: Text((t['name'] as String?) ?? '')),
                  ],
                  onChanged: (v) => setState(() => _templateId = v),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Rinomina',
                  onPressed: tid == null ? null : () => _renameTemplate(tid!)),
              IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.dangerDark),
                  tooltip: 'Elimina',
                  onPressed: tid == null ? null : () => _deleteTemplate(tid!)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (slots.isEmpty || types.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                  'Servono almeno una fascia oraria e un tipo di slot attivi '
                  'per comporre la griglia.',
                  style: AppText.meta),
            )
          else ...[
            _weekdayTabs(context),
            const SizedBox(height: AppSpacing.sm),
            _cellsForDay(tid!, slots, types),
          ],
        ],
      );
    }

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      radius: AppRadius.cardLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('🗓️ Settimana tipo', style: AppText.cardTitle),
              ),
              IconButton(
                icon: Icon(Icons.add_circle,
                    color: Theme.of(context).colorScheme.primary),
                tooltip: 'Nuova settimana',
                onPressed: _newTemplate,
              ),
            ],
          ),
          const Text(
              'Modelli riutilizzabili. Per metterli in calendario attiva le '
              'singole settimane in "Attiva settimane".',
              style: AppText.meta),
          const SizedBox(height: AppSpacing.sm),
          body,
        ],
      ),
    );
  }

  Widget _weekdayTabs(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final wd in _weekdayOrder)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(_weekdayShort[wd]!,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _weekday == wd ? Colors.white : null)),
                selected: _weekday == wd,
                showCheckmark: false,
                selectedColor: primary,
                onSelected: (_) => setState(() => _weekday = wd),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cellsForDay(String templateId, List<Map<String, dynamic>> slots,
      List<Map<String, dynamic>> types) {
    final cellsAsync = ref.watch(templateSlotsProvider(templateId));
    final cells = cellsAsync.value ?? const [];
    if (cellsAsync.isLoading && cells.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: AppLoading(),
      );
    }
    if (cellsAsync.hasError) {
      return AppErrorRetry(
        onRetry: () => ref.invalidate(templateSlotsProvider(templateId)),
      );
    }
    Map<String, dynamic>? cellFor(String timeSlotId) {
      for (final c in cells) {
        if (c['weekday'] == _weekday && c['time_slot_id'] == timeSlotId) {
          return c;
        }
      }
      return null;
    }

    String slotLabel(Map<String, dynamic> ts) {
      String hm(String? t) =>
          (t == null || t.length < 5) ? (t ?? '') : t.substring(0, 5);
      return '${hm(ts['start_time'] as String?)}-${hm(ts['end_time'] as String?)}';
    }

    return Column(
      children: [
        for (final ts in slots)
          _cellRow(templateId, ts['id'] as String, slotLabel(ts),
              cellFor(ts['id'] as String), types),
      ],
    );
  }

  Widget _cellRow(String templateId, String timeSlotId, String label,
      Map<String, dynamic>? cell, List<Map<String, dynamic>> types) {
    final stId = cell?['slot_type_id'] as String?;
    final cap = (cell?['capacity'] as num?)?.toInt();
    final st = types.where((t) => t['id'] == stId).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: AppText.tabularNums)),
          ),
          if (st != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color:
                        OrgBranding.parseHex(st['color'] as String?) ??
                            AppColors.primary,
                    shape: BoxShape.circle),
              ),
            ),
          Expanded(
            child: DropdownButton<String?>(
              value: stId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              hint: const Text('—', style: TextStyle(fontSize: 13)),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('—')),
                for (final t in types)
                  DropdownMenuItem<String?>(
                      value: t['id'] as String,
                      child: Text((t['label'] as String?) ?? '',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => _setCellType(
                  templateId, timeSlotId, v, cell?['id'] as String?),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 58,
            child: TextFormField(
              key: ValueKey('$templateId|$_weekday|$timeSlotId|$stId'),
              initialValue: cap?.toString() ?? '',
              enabled: st != null,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                  hintText: 'cap', isDense: true, counterText: ''),
              onFieldSubmitted: (v) =>
                  _setCellCapacity(cell?['id'] as String?, v),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setCellType(String templateId, String timeSlotId,
      String? slotTypeId, String? existingId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      await repo.setCell(
        templateId: templateId,
        weekday: _weekday,
        timeSlotId: timeSlotId,
        slotTypeId: slotTypeId,
        capacity: null,
        existingId: existingId,
      );
      ref.invalidate(templateSlotsProvider(templateId));
      ref.invalidate(scheduleConfigProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore cella: $e')));
    }
  }

  Future<void> _setCellCapacity(String? existingId, String raw) async {
    if (existingId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final cap = raw.trim().isEmpty ? null : int.tryParse(raw.trim());
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      await repo.setCellCapacity(existingId, cap);
      ref.invalidate(scheduleConfigProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore capienza: $e')));
    }
  }

  Future<String?> _promptName(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _newTemplate() async {
    final messenger = ScaffoldMessenger.of(context);
    final templates = ref.read(allTemplatesProvider).value ?? const [];
    final name =
        await _promptName('Nuova settimana tipo', 'Settimana ${templates.length + 1}');
    if (name == null || name.isEmpty) return;
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      final id = await repo.createTemplate(name, templates.isEmpty);
      ref.invalidate(allTemplatesProvider);
      if (mounted) setState(() => _templateId = id);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore creazione: $e')));
    }
  }

  Future<void> _renameTemplate(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final templates = ref.read(allTemplatesProvider).value ?? const [];
    final cur = templates.where((t) => t['id'] == id).firstOrNull;
    final name =
        await _promptName('Rinomina settimana', (cur?['name'] as String?) ?? '');
    if (name == null || name.isEmpty) return;
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      await repo.renameTemplate(id, name);
      ref.invalidate(allTemplatesProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore rinomina: $e')));
    }
  }

  Future<void> _deleteTemplate(String id) async {
    final templates = ref.read(allTemplatesProvider).value ?? const [];
    final cur = templates.where((t) => t['id'] == id).firstOrNull;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina settimana'),
        content: Text(
            'Eliminare la settimana "${cur?['name'] ?? ''}" e tutte le sue celle?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.dangerDark),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Elimina')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      await repo.deleteTemplate(id);
      ref.invalidate(allTemplatesProvider);
      ref.invalidate(scheduleConfigProvider);
      if (mounted) setState(() => _templateId = null);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore eliminazione: $e')));
    }
  }
}
