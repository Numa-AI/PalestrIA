import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'progress_view.dart';
import 'workout_providers.dart';

/// Vista STORICO (§8.6): card per esercizio, sessioni espandibili per data,
/// righe editabili, elimina set/giornata.
class HistoryView extends ConsumerStatefulWidget {
  const HistoryView({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends ConsumerState<HistoryView> {
  String _query = '';
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(ownPlansProvider).value ?? const <WorkoutPlan>[];
    final logsAsync = ref.watch(allLogsProvider);

    return logsAsync.when(
      loading: () => const AppLoading(),
      error: (_, _) => AppErrorRetry(
        message: 'Errore caricamento storico.',
        onRetry: () => ref.invalidate(allLogsProvider),
      ),
      data: (logs) {
        final groups = buildProgressGroups(plans, logs);
        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? groups
            : groups.where((g) => g.name.toLowerCase().contains(q)).toList();

        return ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            SafeArea(
              bottom: false,
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Torna ai Progressi'),
                  ),
                ],
              ),
            ),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Cerca esercizio...',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (plans.isEmpty)
              const AppEmptyState(
                compact: true,
                title: 'Nessun esercizio nelle tue schede.',
              )
            else if (groups.isEmpty)
              const AppEmptyState(
                compact: true,
                title: 'Nessun log registrato ancora.',
              )
            else if (filtered.isEmpty)
              const AppEmptyState(compact: true, title: 'Nessun risultato.')
            else
              for (final g in filtered) _groupCard(g, logs),
            const SizedBox(height: 100),
          ],
        );
      },
    );
  }

  Widget _groupCard(ProgressGroup g, List<WorkoutLog> logs) {
    final expanded = _expanded.contains(g.key);
    final ids = {for (final e in g.exercises) e.id};
    final groupLogs = logs.where((l) => ids.contains(l.exerciseId)).toList();
    final dates = groupLogs.map((l) => l.logDate).toSet().toList()
      ..sort((a, b) => b.compareTo(a));

    final media =
        ref.watch(catalogMediaProvider(g.exercises.first.planId)).value ??
        const <String, CatalogMedia>{};
    final thumbUrl = g.exercises.first.exerciseSlug == null
        ? null
        : (media[g.exercises.first.exerciseSlug!]?.thumbnail);

    return AppCard(
      margin: const EdgeInsets.only(bottom: 10),
      radius: AppRadius.cardLg,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: thumbUrl == null
                  ? Container(
                      width: 44,
                      height: 44,
                      color: AppColors.slateBg,
                      child: const Icon(
                        Icons.fitness_center,
                        size: 20,
                        color: AppColors.subtle,
                      ),
                    )
                  : CachedNetworkImage(
                      imageUrl: thumbUrl,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                    ),
            ),
            title: Text(
              g.name,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14.5,
              ),
            ),
            subtitle: Text(
              '${groupLogs.length} log · ${dates.length} session${dates.length == 1 ? 'e' : 'i'}',
              style: const TextStyle(fontSize: 12.5),
            ),
            trailing: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
              color: AppColors.subtle,
            ),
            onTap: () => setState(() {
              expanded ? _expanded.remove(g.key) : _expanded.add(g.key);
            }),
          ),
          if (expanded)
            for (final date in dates) _sessionBlock(g, groupLogs, date),
        ],
      ),
    );
  }

  Widget _sessionBlock(
    ProgressGroup g,
    List<WorkoutLog> groupLogs,
    String date,
  ) {
    final sessionLogs = groupLogs.where((l) => l.logDate == date).toList()
      ..sort((a, b) => a.setNumber.compareTo(b.setNumber));
    final d = DateTime.parse(date);
    const months = [
      'Gen',
      'Feb',
      'Mar',
      'Apr',
      'Mag',
      'Giu',
      'Lug',
      'Ago',
      'Set',
      'Ott',
      'Nov',
      'Dic',
    ];
    final label = '${d.day} ${months[d.month - 1]}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: AppColors.navy,
                ),
              ),
              IconButton(
                onPressed: () => _deleteDay(g, sessionLogs, label),
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: AppColors.dangerDark,
                ),
                tooltip: 'Elimina giornata',
              ),
            ],
          ),
          for (final l in sessionLogs) _logRow(g, l),
        ],
      ),
    );
  }

  Widget _logRow(ProgressGroup g, WorkoutLog l) {
    final reps = TextEditingController(text: l.repsDone?.toString() ?? '');
    final weight = TextEditingController(
      text: l.weightDone == null
          ? ''
          : (l.weightDone! % 1 == 0
                ? l.weightDone!.toStringAsFixed(0)
                : l.weightDone!.toStringAsFixed(1)),
    );
    final rest = TextEditingController(text: l.restDone?.toString() ?? '');

    Widget input(TextEditingController c) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.slateBg,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${l.setNumber}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                color: AppColors.muted,
              ),
            ),
          ),
          if (g.isCardio)
            input(reps)
          else ...[
            input(reps),
            input(weight),
            input(rest),
          ],
          IconButton(
            onPressed: () => _saveRow(l, reps, weight, rest, g.isCardio),
            icon: const Icon(
              Icons.check,
              size: 18,
              color: AppColors.successEmeraldDark,
            ),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: () => _deleteSet(l),
            icon: const Icon(
              Icons.close,
              size: 18,
              color: AppColors.dangerDark,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _saveRow(
    WorkoutLog l,
    TextEditingController reps,
    TextEditingController weight,
    TextEditingController rest,
    bool isCardio,
  ) async {
    try {
      await ref.read(workoutRepositoryProvider).updateLog(l.id, {
        'reps_done': int.tryParse(reps.text.trim()),
        if (!isCardio)
          'weight_done': double.tryParse(
            weight.text.trim().replaceAll(',', '.'),
          ),
        if (!isCardio) 'rest_done': int.tryParse(rest.text.trim()),
      });
      _toast('Modifica salvata');
      ref.invalidate(allLogsProvider);
    } catch (_) {
      _toast('Errore di rete. Riprova.', isError: true);
    }
  }

  Future<void> _deleteSet(WorkoutLog l) async {
    final ok = await _confirm('Eliminare questo set?');
    if (ok != true) return;
    try {
      await ref.read(workoutRepositoryProvider).deleteLog(l.id);
      _toast('Set eliminato');
      ref.invalidate(allLogsProvider);
    } catch (_) {
      _toast('Errore di rete. Riprova.', isError: true);
    }
  }

  Future<void> _deleteDay(
    ProgressGroup g,
    List<WorkoutLog> sessionLogs,
    String label,
  ) async {
    final ok = await _confirm('Eliminare tutti i set del $label?');
    if (ok != true) return;
    if (sessionLogs.isEmpty) return;
    try {
      // Una sola DELETE batch invece di N round-trip: più veloce e senza
      // rischio di cancellazione a metà se la rete cade nel mezzo.
      await ref
          .read(workoutRepositoryProvider)
          .deleteLogsOfDay(
            exerciseIds: sessionLogs.map((l) => l.exerciseId).toSet().toList(),
            logDate: sessionLogs.first.logDate,
          );
      _toast('Giornata eliminata');
      ref.invalidate(allLogsProvider);
    } catch (_) {
      _toast('Errore di rete. Riprova.', isError: true);
    }
  }

  Future<bool?> _confirm(String message) => showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Elimina'),
        ),
      ],
    ),
  );

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    if (isError) {
      AppSnack.error(context, message);
    } else {
      AppSnack.success(context, message);
    }
  }
}
