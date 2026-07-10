import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'exercise_media.dart';
import 'workout_providers.dart';

/// Overlay dettaglio esercizio/superset/circuito con sezione log (§8.4).
Future<void> showExerciseDetailSheet(
  BuildContext context,
  WidgetRef ref,
  WorkoutPlan plan,
  ExerciseGroup group,
) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ExerciseDetailPage(plan: plan, group: group),
    ),
  );
}

class _ExerciseDetailPage extends ConsumerWidget {
  const _ExerciseDetailPage({required this.plan, required this.group});

  final WorkoutPlan plan;
  final ExerciseGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = switch (group.kind) {
      ExerciseGroupKind.single => group.first.exerciseName,
      ExerciseGroupKind.superset => 'Super Serie',
      ExerciseGroupKind.circuit => 'Circuito',
    };
    final media =
        ref.watch(catalogMediaProvider(plan.id)).value ??
        const <String, CatalogMedia>{};

    return Scaffold(
      backgroundColor: AppColors.slateBg,
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (group.kind == ExerciseGroupKind.circuit)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(
                '${group.first.sets} giri · ${group.exercises.length} esercizi'
                '${group.exercises.map((e) => e.restSeconds).where((r) => r > 0).isNotEmpty ? ' · ${group.exercises.map((e) => e.restSeconds).where((r) => r > 0).last}s pausa' : ''}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ),
          for (var i = 0; i < group.exercises.length; i++) ...[
            if (group.exercises.length > 1)
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpacing.md,
                  bottom: AppSpacing.sm,
                ),
                child: Text(
                  group.kind == ExerciseGroupKind.superset
                      ? 'Esercizio ${i + 1}'
                      : 'Esercizio ${i + 1} di ${group.exercises.length}',
                  style: AppText.eyebrow,
                ),
              ),
            _ExerciseBlock(
              plan: plan,
              exercise: group.exercises[i],
              media: media[group.exercises[i].exerciseSlug],
            ),
            if (i < group.exercises.length - 1)
              const Divider(height: AppSpacing.xxl),
          ],
        ],
      ),
    );
  }
}

class _ExerciseBlock extends ConsumerStatefulWidget {
  const _ExerciseBlock({
    required this.plan,
    required this.exercise,
    required this.media,
  });

  final WorkoutPlan plan;
  final WorkoutExercise exercise;
  final CatalogMedia? media;

  @override
  ConsumerState<_ExerciseBlock> createState() => _ExerciseBlockState();
}

class _ExerciseBlockState extends ConsumerState<_ExerciseBlock> {
  final List<_SetRow> _rows = [];
  bool _initialized = false;
  bool _saving = false;
  bool _saved = false;

  WorkoutExercise get e => widget.exercise;

  void _initRows(List<WorkoutLog> logs) {
    if (_initialized) return;
    _initialized = true;

    final today = todayYmd();
    final todayLogs =
        logs.where((l) => l.exerciseId == e.id && l.logDate == today).toList()
          ..sort((a, b) => a.setNumber.compareTo(b.setNumber));

    // sessione precedente = data di log più recente ≠ oggi
    final prevDate = logs
        .where((l) => l.exerciseId == e.id && l.logDate != today)
        .map((l) => l.logDate)
        .fold<String?>(
          null,
          (max, d) => max == null || d.compareTo(max) > 0 ? d : max,
        );
    final prevLogs = prevDate == null
        ? const <WorkoutLog>[]
        : (logs
              .where((l) => l.exerciseId == e.id && l.logDate == prevDate)
              .toList()
            ..sort((a, b) => a.setNumber.compareTo(b.setNumber)));

    final count = e.isCardio ? 1 : e.sets;
    for (var i = 1; i <= count; i++) {
      final today0 = todayLogs.where((l) => l.setNumber == i).firstOrNull;
      final prev0 = prevLogs.where((l) => l.setNumber == i).firstOrNull;
      _rows.add(
        _SetRow(
          setNumber: i,
          reps: TextEditingController(
            text:
                (today0?.repsDone ?? prev0?.repsDone)?.toString() ??
                (int.tryParse(e.reps)?.toString() ?? e.reps),
          ),
          weight: TextEditingController(
            text: _fmtW(today0?.weightDone ?? prev0?.weightDone ?? e.weightKg),
          ),
          rest: TextEditingController(
            text: (today0?.restDone ?? prev0?.restDone ?? e.restSeconds)
                .toString(),
          ),
        ),
      );
    }
    // righe extra registrate oggi oltre i set target
    for (final l in todayLogs.where((l) => l.setNumber > count)) {
      _rows.add(
        _SetRow(
          setNumber: l.setNumber,
          reps: TextEditingController(text: l.repsDone?.toString() ?? ''),
          weight: TextEditingController(text: _fmtW(l.weightDone)),
          rest: TextEditingController(text: l.restDone?.toString() ?? ''),
        ),
      );
    }
  }

  static String _fmtW(double? w) {
    if (w == null) return '';
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toStringAsFixed(1);
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;
    setState(() {
      _saving = true;
      _saved = false;
    });
    final repo = ref.read(workoutRepositoryProvider);
    final today = todayYmd();
    try {
      for (final row in _rows) {
        final reps = int.tryParse(row.reps.text.trim());
        final weight = double.tryParse(
          row.weight.text.trim().replaceAll(',', '.'),
        );
        final rest = int.tryParse(row.rest.text.trim());
        if (reps == null && weight == null) continue;
        await repo.logSet(
          exerciseId: e.id,
          userId: session.user.id,
          logDate: today,
          setNumber: row.setNumber,
          repsDone: reps,
          weightDone: weight,
          restDone: rest,
        );
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saved = true;
      });
      AppSnack.success(context, 'Log salvato');
      ref.invalidate(planLogsProvider(widget.plan.id));
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _saved = false);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnack.error(context, 'Errore nel salvataggio');
    }
  }

  Future<void> _deleteToday(List<WorkoutLog> logs) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('Eliminare il log di oggi per questo esercizio?'),
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
    if (ok != true) return;
    final today = todayYmd();
    final repo = ref.read(workoutRepositoryProvider);
    // Una sola DELETE batch (tutti i set di oggi dell'esercizio) invece di N.
    await repo.deleteLogsOfDay(exerciseIds: [e.id], logDate: today);
    if (!mounted) return;
    AppSnack.success(context, 'Log eliminato');
    ref.invalidate(planLogsProvider(widget.plan.id));
    setState(() {
      _initialized = false;
      _rows.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(planLogsProvider(widget.plan.id));
    final logs = logsAsync.value ?? const <WorkoutLog>[];
    _initRows(logs);

    final today = todayYmd();
    final hasToday = logs.any(
      (l) => l.exerciseId == e.id && l.logDate == today,
    );
    final prevDate = logs
        .where((l) => l.exerciseId == e.id && l.logDate != today)
        .map((l) => l.logDate)
        .fold<String?>(
          null,
          (max, d) => max == null || d.compareTo(max) > 0 ? d : max,
        );

    final imageUrl = widget.media?.image ?? widget.media?.thumbnail;
    final videoUrl = widget.media?.video;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExerciseMediaView(videoUrl: videoUrl, imageUrl: imageUrl),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            const Text(
              'DA FARE:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                e.targetLabel,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
            ),
          ],
        ),
        if (e.notes != null && e.notes!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              e.notes!,
              style: const TextStyle(
                fontStyle: FontStyle.italic,
                color: AppColors.muted,
                fontSize: 13,
              ),
            ),
          ),
        if (prevDate != null) _previousSession(logs, prevDate),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'REGISTRA PER OGGI — ${_dateLabel(today)}',
          style: AppText.eyebrow,
        ),
        const SizedBox(height: AppSpacing.sm),
        _logGrid(),
        TextButton.icon(
          onPressed: () => setState(() {
            _rows.add(
              _SetRow(
                setNumber: _rows.length + 1,
                reps: TextEditingController(),
                weight: TextEditingController(),
                rest: TextEditingController(),
              ),
            );
          }),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('+ Serie'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: _saved ? AppColors.successEmerald : null,
          ),
          child: Text(
            _saving
                ? 'Salvataggio...'
                : _saved
                ? 'Salvato!'
                : 'SALVA',
          ),
        ),
        if (hasToday)
          TextButton(
            onPressed: () => _deleteToday(logs),
            style: TextButton.styleFrom(foregroundColor: AppColors.dangerDark),
            child: const Text('Elimina log di oggi'),
          ),
      ],
    );
  }

  Widget _previousSession(List<WorkoutLog> logs, String prevDate) {
    final prev =
        logs
            .where((l) => l.exerciseId == e.id && l.logDate == prevDate)
            .toList()
          ..sort((a, b) => a.setNumber.compareTo(b.setNumber));

    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFEFCE8), AppColors.warnSurface],
        ),
        border: const Border(
          left: BorderSide(color: AppColors.amber, width: 3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sessione precedente — ${_dateLabel(prevDate)}',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: AppColors.docWarnText,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final l in prev)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Text(
                    e.isCardio
                        ? '${l.repsDone ?? '-'} min'
                        : '${l.setNumber}. ${l.repsDone ?? '-'}×${_fmtW(l.weightDone)}kg',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      fontFeatures: AppText.tabularNums,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _logGrid() {
    Widget header(String t) => Expanded(
      child: Text(
        t,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );

    Widget input(TextEditingController c) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            fontFeatures: AppText.tabularNums,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.slateBg,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );

    Widget setHeader() => const SizedBox(
      width: 28,
      child: Text(
        'Serie',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );

    return Column(
      children: [
        Row(
          children: [
            setHeader(),
            if (e.isCardio)
              header('Min')
            else ...[
              header('Ripetizioni'),
              header('Kg'),
              header('Riposo'),
            ],
          ],
        ),
        const SizedBox(height: 4),
        for (final row in _rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '${row.setNumber}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                if (e.isCardio)
                  input(row.reps)
                else ...[
                  input(row.reps),
                  input(row.weight),
                  input(row.rest),
                ],
              ],
            ),
          ),
      ],
    );
  }

  static String _dateLabel(String ymd) {
    final d = DateTime.parse(ymd);
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
    return '${d.day} ${months[d.month - 1]}';
  }
}

class _SetRow {
  _SetRow({
    required this.setNumber,
    required this.reps,
    required this.weight,
    required this.rest,
  });

  final int setNumber;
  final TextEditingController reps;
  final TextEditingController weight;
  final TextEditingController rest;
}
