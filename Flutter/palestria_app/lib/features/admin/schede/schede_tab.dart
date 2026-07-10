import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/workout/add_exercise_flows.dart';
import '../../client/workout/workout_providers.dart';
import 'admin_progress_view.dart';
import 'schede_edit.dart';
import 'schede_providers.dart';

/// Tab Schede (spec-admin §9): elenco schede dei clienti con **editing**
/// (rinomina scheda, aggiungi/modifica/elimina esercizio per giorno, blocchi
/// Super Serie/Circuito, riordino) + vista **Progressi** per cliente. Riusa
/// `WorkoutRepository` (CRUD per-id, RLS org-admin) e i flussi di aggiunta del
/// cliente (`showAddToDay`) col catalogo esercizi.
class SchedeTab extends ConsumerWidget {
  const SchedeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(orgPlansProvider);

    return plansAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore: $e',
        onRetry: () => ref.invalidate(orgPlansProvider),
      ),
      data: (plans) {
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(orgPlansProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
            children: [
              const Text('Schede', style: AppText.pageTitle),
              const SizedBox(height: AppSpacing.md),
              if (plans.isEmpty)
                const AppEmptyState(
                  title: 'Nessuna scheda assegnata.',
                  icon: Icons.fitness_center_outlined,
                )
              else
                for (final p in plans) _planCard(context, ref, p),
            ],
          ),
        );
      },
    );
  }

  Widget _planCard(BuildContext context, WidgetRef ref, WorkoutPlan plan) {
    final primary = Theme.of(context).colorScheme.primary;
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(Icons.fitness_center, color: primary),
        title: Text(plan.name,
            style:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
        subtitle: Text(
            '${plan.dayLabels.length} giorn${plan.dayLabels.length == 1 ? 'o' : 'i'} · ${plan.exercises.length} esercizi',
            style: const TextStyle(fontSize: 12.5)),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'rename') {
              _renamePlan(context, ref, plan);
            } else if (v == 'progress') {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AdminClientProgressScreen(
                    userId: plan.userId, title: plan.name),
              ));
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'progress', child: Text('Progressi cliente')),
            PopupMenuItem(value: 'rename', child: Text('Rinomina scheda')),
          ],
        ),
        children: [
          for (final day in plan.dayLabels)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                          child:
                              Text(day.toUpperCase(), style: AppText.eyebrow)),
                      _addMenu(context, ref, plan, day),
                    ],
                  ),
                  _dayBlocks(context, ref, plan, day),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _addMenu(
      BuildContext context, WidgetRef ref, WorkoutPlan plan, String day) {
    return PopupMenuButton<String>(
      tooltip: 'Aggiungi',
      icon: const Icon(Icons.add_circle_outline, size: 20),
      onSelected: (v) {
        switch (v) {
          case 'manual':
            showExerciseEditSheet(context, ref,
                planId: plan.id,
                dayLabel: day,
                sortOrder: plan.exercises.length);
          case 'catalog':
            showAddToDay(context, ref, plan, day,
                onChanged: () => ref.invalidate(orgPlansProvider));
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'manual', child: Text('Esercizio (manuale)')),
        PopupMenuItem(
            value: 'catalog',
            child: Text('Dal catalogo / Super Serie / Circuito…')),
      ],
    );
  }

  Widget _dayBlocks(
      BuildContext context, WidgetRef ref, WorkoutPlan plan, String day) {
    final groups = groupExercises(plan.exercisesOf(day));
    return Column(
      children: [
        for (var gi = 0; gi < groups.length; gi++)
          _block(context, ref, plan, groups, gi),
      ],
    );
  }

  Widget _block(BuildContext context, WidgetRef ref, WorkoutPlan plan,
      List<ExerciseGroup> groups, int index) {
    final g = groups[index];
    final reorder = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _arrow(Icons.keyboard_arrow_up, index > 0,
            () => _reorderBlock(ref, plan, groups, index, -1)),
        _arrow(Icons.keyboard_arrow_down, index < groups.length - 1,
            () => _reorderBlock(ref, plan, groups, index, 1)),
      ],
    );

    if (g.kind == ExerciseGroupKind.single) {
      final e = g.first;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            reorder,
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.exerciseName, style: const TextStyle(fontSize: 13)),
                  Text(e.targetLabel,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.muted)),
                ],
              ),
            ),
            _iconBtn(Icons.edit, 'Modifica',
                () => showExerciseEditSheet(context, ref, existing: e)),
            _iconBtn(Icons.delete_outline, 'Elimina',
                () => _deleteExercise(context, ref, e),
                danger: true),
          ],
        ),
      );
    }

    // Blocco Super Serie / Circuito
    final isSS = g.kind == ExerciseGroupKind.superset;
    final accent = isSS ? const Color(0xFFF59E0B) : const Color(0xFF06B6D4);
    final label = isSS ? 'SUPER SERIE' : 'CIRCUITO';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border.all(color: accent, width: 1.5),
        borderRadius: BorderRadius.circular(12),
        color: accent.withValues(alpha: 0.04),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                        color: Colors.white)),
              ),
              const Spacer(),
              reorder,
              _iconBtn(Icons.delete_outline, 'Elimina blocco',
                  () => _deleteBlock(context, ref, g),
                  danger: true),
            ],
          ),
          for (final e in g.exercises)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.exerciseName,
                            style: const TextStyle(fontSize: 13)),
                        Text(e.targetLabel,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  _iconBtn(Icons.edit, 'Modifica',
                      () => showExerciseEditSheet(context, ref, existing: e)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _arrow(IconData icon, bool enabled, VoidCallback onTap) => InkResponse(
        onTap: enabled ? onTap : null,
        radius: 16,
        child: Icon(icon,
            size: 20,
            color: enabled
                ? AppColors.muted
                : AppColors.subtle.withValues(alpha: 0.4)),
      );

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onTap,
          {bool danger = false}) =>
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: Icon(icon,
            size: 17, color: danger ? AppColors.dangerDark : null),
        tooltip: tooltip,
        onPressed: onTap,
      );

  /// Sposta il blocco su/giù nel giorno e rinumera i sort_order via
  /// reorderExercises (base-min, come il web).
  Future<void> _reorderBlock(WidgetRef ref, WorkoutPlan plan,
      List<ExerciseGroup> groups, int index, int direction) async {
    final target = index + direction;
    if (target < 0 || target >= groups.length) return;
    final reordered = [...groups];
    final moved = reordered.removeAt(index);
    reordered.insert(target, moved);
    final flat = [for (final grp in reordered) ...grp.exercises];
    try {
      await ref.read(workoutRepositoryProvider).reorderExercises(flat);
      ref.invalidate(orgPlansProvider);
    } catch (_) {/* la lista resta invariata */}
  }

  Future<void> _deleteBlock(
      BuildContext context, WidgetRef ref, ExerciseGroup g) async {
    final kind =
        g.kind == ExerciseGroupKind.superset ? 'la super serie' : 'il circuito';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina blocco'),
        content: Text('Eliminare $kind (${g.exercises.length} esercizi)?'),
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
    if (ok != true || !context.mounted) return;
    try {
      await ref
          .read(workoutRepositoryProvider)
          .deleteExercises([for (final e in g.exercises) e.id]);
      ref.invalidate(orgPlansProvider);
      if (context.mounted) AppSnack.success(context, 'Blocco eliminato.');
    } catch (err) {
      if (context.mounted) AppSnack.error(context, 'Errore: $err');
    }
  }

  Future<void> _renamePlan(
      BuildContext context, WidgetRef ref, WorkoutPlan plan) async {
    final controller = TextEditingController(text: plan.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rinomina scheda'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annulla')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Salva')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == plan.name || !context.mounted) {
      return;
    }
    try {
      await ref.read(workoutRepositoryProvider).updatePlan(plan.id, {'name': name});
      ref.invalidate(orgPlansProvider);
      if (context.mounted) AppSnack.success(context, 'Scheda rinominata.');
    } catch (e) {
      if (context.mounted) AppSnack.error(context, 'Errore: $e');
    }
  }

  Future<void> _deleteExercise(
      BuildContext context, WidgetRef ref, WorkoutExercise e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Elimina esercizio'),
        content: Text('Eliminare "${e.exerciseName}" dalla scheda?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.dangerDark),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Elimina')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(workoutRepositoryProvider).deleteExercise(e.id);
      ref.invalidate(orgPlansProvider);
      if (context.mounted) AppSnack.success(context, 'Esercizio eliminato.');
    } catch (err) {
      if (context.mounted) AppSnack.error(context, 'Errore: $err');
    }
  }
}
