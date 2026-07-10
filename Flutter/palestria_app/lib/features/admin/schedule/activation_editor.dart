import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

const _windowWeeks = 8;

/// Editor "Attiva settimane" (port di _schedRenderActivation §Editor3.5): il
/// calendario si attiva una settimana alla volta puntando a un template.
/// Finestra: settimana corrente + prossime; sotto, le altre settimane attivate.
class ActivationEditorSection extends ConsumerStatefulWidget {
  const ActivationEditorSection({super.key});

  @override
  ConsumerState<ActivationEditorSection> createState() =>
      _ActivationEditorSectionState();
}

class _ActivationEditorSectionState
    extends ConsumerState<ActivationEditorSection> {
  final Map<String, String> _selected = {}; // weekStart → templateId

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String _dm(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';

  DateTime _mondayOf(DateTime d) =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));

  @override
  Widget build(BuildContext context) {
    final templatesAsync = ref.watch(allTemplatesProvider);
    final activatedAsync = ref.watch(activatedWeeksProvider);
    final templates = templatesAsync.value ?? const [];
    final activated = activatedAsync.value ?? const [];
    final activeMap = <String, String>{
      for (final a in activated)
        (a['week_start'] as String).substring(0, 10):
            a['template_id'] as String
    };
    final loading = (templatesAsync.isLoading && templates.isEmpty) ||
        (activatedAsync.isLoading && activated.isEmpty);
    final hasError = templatesAsync.hasError || activatedAsync.hasError;

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
          ref.invalidate(activatedWeeksProvider);
        },
      );
    } else if (templates.isEmpty) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text('Crea prima almeno una settimana tipo da applicare.',
            style: AppText.meta),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i <= _windowWeeks; i++)
            _weekRow(context,
                _mondayOf(DateTime.now()).add(Duration(days: i * 7)),
                templates, activeMap, i == 0),
          ..._outsideRows(context, templates, activeMap),
        ],
      );
    }

    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      radius: AppRadius.cardLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('📆 Attiva settimane', style: AppText.cardTitle),
          const Text(
              'Attiva il calendario una settimana alla volta scegliendo il '
              'template. Le settimane non attivate non mostrano slot.',
              style: AppText.meta),
          const SizedBox(height: AppSpacing.sm),
          body,
        ],
      ),
    );
  }

  List<Widget> _outsideRows(BuildContext context,
      List<Map<String, dynamic>> templates, Map<String, String> activeMap) {
    final startMon = _mondayOf(DateTime.now());
    final windowKeys = {
      for (var i = 0; i <= _windowWeeks; i++)
        _ymd(startMon.add(Duration(days: i * 7)))
    };
    final outside = activeMap.keys.where((k) => !windowKeys.contains(k)).toList()
      ..sort();
    if (outside.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: 8, bottom: 4),
        child: Text('Altre settimane attivate', style: AppText.meta),
      ),
      for (final ymd in outside)
        _weekRow(context, DateTime.parse(ymd), templates, activeMap, false),
    ];
  }

  Widget _weekRow(BuildContext context, DateTime monday,
      List<Map<String, dynamic>> templates, Map<String, String> activeMap,
      bool isCurrent) {
    final ymd = _ymd(monday);
    final sunday = monday.add(const Duration(days: 6));
    final isActive = activeMap.containsKey(ymd);
    final defaultTpl = activeMap[ymd] ?? templates.first['id'] as String;
    final selected = _selected[ymd] ?? defaultTpl;
    final range = '${_dm(monday)} – ${_dm(sunday)}/${sunday.year}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('🗓️ $range',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            isCurrent ? FontWeight.w800 : FontWeight.w600,
                        fontFeatures: AppText.tabularNums)),
              ),
              if (isActive)
                const Icon(Icons.check_circle,
                    size: 16, color: AppColors.green500)
              else
                const Icon(Icons.circle_outlined,
                    size: 16, color: AppColors.subtle),
            ],
          ),
          if (isCurrent)
            Text('questa settimana',
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: selected,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final t in templates)
                      DropdownMenuItem(
                          value: t['id'] as String,
                          child: Text((t['name'] as String?) ?? '',
                              overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) =>
                      setState(() => _selected[ymd] = v ?? defaultTpl),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: () => _activate(ymd, selected, activeMap),
                style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                child: Text(isActive ? 'Aggiorna' : 'Attiva'),
              ),
              if (isActive)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: AppColors.dangerDark),
                  tooltip: 'Disattiva',
                  onPressed: () => _deactivate(ymd),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _activate(
      String weekStart, String tplId, Map<String, String> activeMap) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      final existing = activeMap[weekStart];
      if (existing != null && existing != tplId) {
        if (await repo.weekHasBookings(weekStart)) {
          messenger.showSnackBar(const SnackBar(
              content: Text(
                  'Settimana con prenotazioni attive: non puoi cambiarne il '
                  'template.')));
          return;
        }
      }
      await repo.activateWeek(weekStart, tplId);
      ref.invalidate(activatedWeeksProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger
          .showSnackBar(const SnackBar(content: Text('Settimana attivata.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore attivazione: $e')));
    }
  }

  Future<void> _deactivate(String weekStart) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) {
        if (!mounted) return;
        AppSnack.error(context, 'Non autorizzato');
        return;
      }
      if (await repo.weekHasBookings(weekStart)) {
        messenger.showSnackBar(const SnackBar(
            content: Text(
                'Settimana con prenotazioni attive: non puoi disattivarla.')));
        return;
      }
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Disattiva settimana'),
          content: const Text(
              'Disattivare questa settimana? Gli slot non saranno più '
              'disponibili (le prenotazioni esistenti restano nel registro).'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annulla')),
            FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.dangerDark),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Disattiva')),
          ],
        ),
      );
      if (ok != true) return;
      await repo.deactivateWeek(weekStart);
      ref.invalidate(activatedWeeksProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger.showSnackBar(
          const SnackBar(content: Text('Settimana disattivata.')));
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Errore disattivazione: $e')));
    }
  }
}
