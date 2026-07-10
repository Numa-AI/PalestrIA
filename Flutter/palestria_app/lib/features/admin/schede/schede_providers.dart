import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';

/// Tutte le schede attive della org (per l'admin), con esercizi embedded.
final orgPlansProvider = FutureProvider<List<WorkoutPlan>>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  if (orgContext.orgId == null || !orgContext.isOrgAdmin) return const [];
  final client = ref.read(supabaseProvider);
  final rows = await client
      .from('workout_plans')
      .select('*, workout_exercises(*)')
      .eq('org_id', orgContext.orgId!)
      .eq('active', true)
      .order('updated_at', ascending: false)
      .timeout(const Duration(seconds: 30));
  return [for (final r in rows) WorkoutPlan.fromRow(r)];
});

/// Log workout di un cliente (per la vista Progressi admin): tutti i log degli
/// esercizi delle schede di quel `userId` nella org. RLS org-admin.
final adminClientLogsProvider = FutureProvider.autoDispose
    .family<List<WorkoutLog>, String>((ref, userId) async {
      final plans = await ref.watch(orgPlansProvider.future);
      final ids = [
        for (final p in plans)
          if (p.userId == userId)
            for (final e in p.exercises) e.id,
      ];
      if (ids.isEmpty) return const [];
      return ref.read(workoutRepositoryProvider).fetchLogsForExercises(ids);
    });
