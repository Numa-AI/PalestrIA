import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import 'schede_edit.dart';
import 'schede_providers.dart';

/// Tab Schede (spec-admin §9): elenco schede dei clienti con **editing**
/// (rinomina scheda, aggiungi/modifica/elimina esercizio per giorno). Riusa
/// `WorkoutRepository` (CRUD per-id, RLS org-admin). Il picker catalogo e la
/// vista "allenamento dal vivo" restano sul web.
class SchedeTab extends ConsumerWidget {
  const SchedeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(orgPlansProvider);

    return plansAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Errore: $e')),
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
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.xl),
                  child: Text('Nessuna scheda assegnata.',
                      textAlign: TextAlign.center, style: AppText.meta),
                )
              else
                for (final p in plans) _planCard(context, ref, p),
              const SizedBox(height: AppSpacing.md),
              const Text(
                'Il picker dal catalogo esercizi e la vista "allenamento dal '
                'vivo" restano (per ora) sul pannello web.',
                style: TextStyle(fontSize: 12, color: AppColors.subtle),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _planCard(BuildContext context, WidgetRef ref, WorkoutPlan plan) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.fitness_center, color: AppColors.primary),
        title: Text(plan.name,
            style:
                const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
        subtitle: Text(
            '${plan.dayLabels.length} giorn${plan.dayLabels.length == 1 ? 'o' : 'i'} · ${plan.exercises.length} esercizi',
            style: const TextStyle(fontSize: 12.5)),
        trailing: PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'rename') _renamePlan(context, ref, plan);
          },
          itemBuilder: (_) => const [
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
                      TextButton.icon(
                        onPressed: () => showExerciseEditSheet(context, ref,
                            planId: plan.id,
                            dayLabel: day,
                            sortOrder: plan.exercises.length),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Esercizio',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  for (final e in plan.exercisesOf(day))
                    _exerciseRow(context, ref, e),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _exerciseRow(
      BuildContext context, WidgetRef ref, WorkoutExercise e) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.exerciseName, style: const TextStyle(fontSize: 13)),
                Text(e.targetLabel,
                    style:
                        const TextStyle(fontSize: 11.5, color: AppColors.muted)),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit, size: 17),
            tooltip: 'Modifica',
            onPressed: () =>
                showExerciseEditSheet(context, ref, existing: e),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline,
                size: 17, color: Color(0xFFDC2626)),
            tooltip: 'Elimina',
            onPressed: () => _deleteExercise(context, ref, e),
          ),
        ],
      ),
    );
  }

  Future<void> _renamePlan(
      BuildContext context, WidgetRef ref, WorkoutPlan plan) async {
    final messenger = ScaffoldMessenger.of(context);
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
    if (name == null || name.isEmpty || name == plan.name) return;
    try {
      await ref.read(workoutRepositoryProvider).updatePlan(plan.id, {'name': name});
      ref.invalidate(orgPlansProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Scheda rinominata.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    }
  }

  Future<void> _deleteExercise(
      BuildContext context, WidgetRef ref, WorkoutExercise e) async {
    final messenger = ScaffoldMessenger.of(context);
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
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Elimina')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(workoutRepositoryProvider).deleteExercise(e.id);
      ref.invalidate(orgPlansProvider);
      messenger
          .showSnackBar(const SnackBar(content: Text('Esercizio eliminato.')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $err')));
    }
  }
}
