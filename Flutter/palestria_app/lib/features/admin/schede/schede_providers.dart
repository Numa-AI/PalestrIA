import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
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
