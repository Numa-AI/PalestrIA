import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';

/// Schede attive dell'utente (con esercizi embedded).
final ownPlansProvider = FutureProvider<List<WorkoutPlan>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(workoutRepositoryProvider).fetchOwnPlans(session.user.id);
});

/// Log del piano corrente (family per planId).
final planLogsProvider = FutureProvider.autoDispose
    .family<List<WorkoutLog>, String>((ref, planId) async {
      final plans = await ref.watch(ownPlansProvider.future);
      final plan = plans.where((p) => p.id == planId).firstOrNull;
      if (plan == null) return const [];
      final ids = [for (final e in plan.exercises) e.id];
      return ref.read(workoutRepositoryProvider).fetchLogsForExercises(ids);
    });

/// Thumbnail/video del catalogo per gli slug degli esercizi del piano.
final catalogMediaProvider = FutureProvider.autoDispose
    .family<Map<String, CatalogMedia>, String>((ref, planId) async {
      final plans = await ref.watch(ownPlansProvider.future);
      final plan = plans.where((p) => p.id == planId).firstOrNull;
      if (plan == null) return const {};
      final slugs = {
        for (final e in plan.exercises)
          if (e.exerciseSlug != null && e.exerciseSlug!.isNotEmpty)
            e.exerciseSlug!,
      }.toList();
      if (slugs.isEmpty) return const {};
      final rows = await ref
          .read(supabaseProvider)
          .from('imported_exercises')
          .select('slug, immagine, immagine_thumbnail, video')
          .inFilter('slug', slugs)
          .timeout(const Duration(seconds: 15));
      return {
        for (final r in rows)
          (r['slug'] as String): CatalogMedia(
            image: r['immagine'] as String?,
            thumbnail: r['immagine_thumbnail'] as String?,
            video: r['video'] as String?,
          ),
      };
    });

class CatalogMedia {
  const CatalogMedia({this.image, this.thumbnail, this.video});
  final String? image;
  final String? thumbnail;
  final String? video;
}

/// Elemento renderizzabile della scheda: singolo, superset o circuito.
class ExerciseGroup {
  const ExerciseGroup(this.exercises, this.kind);

  final List<WorkoutExercise> exercises;
  final ExerciseGroupKind kind;

  WorkoutExercise get first => exercises.first;
}

enum ExerciseGroupKind { single, superset, circuit }

/// Raggruppa gli esercizi di un giorno in card (per superset/circuit_group),
/// mantenendo l'ordine del sort_order.
List<ExerciseGroup> groupExercises(List<WorkoutExercise> dayExercises) {
  final groups = <ExerciseGroup>[];
  final consumed = <String>{};
  for (final e in dayExercises) {
    if (consumed.contains(e.id)) continue;
    if (e.supersetGroup != null) {
      final members = dayExercises
          .where((x) => x.supersetGroup == e.supersetGroup)
          .toList();
      consumed.addAll(members.map((m) => m.id));
      groups.add(ExerciseGroup(members, ExerciseGroupKind.superset));
    } else if (e.circuitGroup != null) {
      final members = dayExercises
          .where((x) => x.circuitGroup == e.circuitGroup)
          .toList();
      consumed.addAll(members.map((m) => m.id));
      groups.add(ExerciseGroup(members, ExerciseGroupKind.circuit));
    } else {
      consumed.add(e.id);
      groups.add(ExerciseGroup([e], ExerciseGroupKind.single));
    }
  }
  return groups;
}

String todayYmd() => OrgScheduleConfig.localDateStr(DateTime.now());

/// true se l'esercizio ha almeno un log di oggi.
bool doneToday(WorkoutExercise e, List<WorkoutLog> logs) =>
    logs.any((l) => l.exerciseId == e.id && l.logDate == todayYmd());

/// Ultima data di log per un insieme di esercizi (per il meta dei giorni).
String? lastLogDate(List<WorkoutExercise> exercises, List<WorkoutLog> logs) {
  final ids = {for (final e in exercises) e.id};
  String? last;
  for (final l in logs) {
    if (!ids.contains(l.exerciseId)) continue;
    if (last == null || l.logDate.compareTo(last) > 0) last = l.logDate;
  }
  return last;
}
