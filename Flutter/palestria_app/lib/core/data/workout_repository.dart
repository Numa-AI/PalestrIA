import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../models/workout.dart';

/// Repository workout lato cliente (port di WorkoutPlanStorage /
/// WorkoutLogStorage, spec-data §5.5). CRUD con timeout 15 s.
class WorkoutRepository {
  WorkoutRepository(this._client);

  final SupabaseClient _client;

  static const _crudTimeout = Duration(seconds: 15);

  /// Schede attive dell'utente con esercizi embedded, ordinate per updated_at.
  Future<List<WorkoutPlan>> fetchOwnPlans(String userId) async {
    final rows = await _client
        .from('workout_plans')
        .select('*, workout_exercises(*)')
        .eq('user_id', userId)
        .eq('active', true)
        .order('updated_at', ascending: false)
        .timeout(const Duration(seconds: 30));
    return [for (final r in rows) WorkoutPlan.fromRow(r)];
  }

  /// Log per gli esercizi di un piano, paginati (batch 1000 con tiebreaker id).
  Future<List<WorkoutLog>> fetchLogsForExercises(
      List<String> exerciseIds) async {
    if (exerciseIds.isEmpty) return const [];
    final all = <WorkoutLog>[];
    var from = 0;
    const batch = 1000;
    while (true) {
      final rows = await _client
          .from('workout_logs')
          .select(
              'id, exercise_id, user_id, log_date, set_number, reps_done, weight_done, rest_done, rpe, notes')
          .inFilter('exercise_id', exerciseIds)
          .order('log_date', ascending: false)
          .order('set_number', ascending: true)
          .order('id')
          .range(from, from + batch - 1)
          .timeout(const Duration(seconds: 30));
      all.addAll([for (final r in rows) WorkoutLog.fromRow(r)]);
      if (rows.length < batch) break;
      from += batch;
    }
    return all;
  }

  /// Upsert di un set (onConflict exercise_id,user_id,log_date,set_number).
  Future<void> logSet({
    required String exerciseId,
    required String userId,
    required String logDate,
    required int setNumber,
    int? repsDone,
    double? weightDone,
    int? restDone,
  }) async {
    await _client.from('workout_logs').upsert(
      {
        'exercise_id': exerciseId,
        'user_id': userId,
        'log_date': logDate,
        'set_number': setNumber,
        'reps_done': repsDone,
        'weight_done': weightDone,
        'rest_done': restDone,
      },
      onConflict: 'exercise_id,user_id,log_date,set_number',
    ).timeout(_crudTimeout);
  }

  Future<void> deleteLog(String logId) async {
    await _client
        .from('workout_logs')
        .delete()
        .eq('id', logId)
        .timeout(_crudTimeout);
  }

  Future<void> deleteLogsOfDay({
    required List<String> exerciseIds,
    required String logDate,
  }) async {
    if (exerciseIds.isEmpty) return;
    await _client
        .from('workout_logs')
        .delete()
        .inFilter('exercise_id', exerciseIds)
        .eq('log_date', logDate)
        .timeout(_crudTimeout);
  }

  Future<void> updateLog(String logId, Map<String, dynamic> updates) async {
    await _client
        .from('workout_logs')
        .update(updates)
        .eq('id', logId)
        .timeout(_crudTimeout);
  }

  Future<WorkoutPlan> createPlan({
    required String userId,
    required String name,
    String? notes,
  }) async {
    final row = await _client
        .from('workout_plans')
        .insert({
          'user_id': userId,
          'name': name,
          'notes': notes,
          'active': true,
        })
        .select('*, workout_exercises(*)')
        .single()
        .timeout(_crudTimeout);
    return WorkoutPlan.fromRow(row);
  }

  Future<void> updatePlan(String planId, Map<String, dynamic> updates) async {
    await _client
        .from('workout_plans')
        .update(updates)
        .eq('id', planId)
        .timeout(_crudTimeout);
  }

  Future<void> updateExercise(
      String exerciseId, Map<String, dynamic> updates) async {
    await _client
        .from('workout_exercises')
        .update(updates)
        .eq('id', exerciseId)
        .timeout(_crudTimeout);
  }

  Future<void> deleteExercise(String exerciseId) async {
    await _client
        .from('workout_exercises')
        .delete()
        .eq('id', exerciseId)
        .timeout(_crudTimeout);
  }

  Future<void> deleteExercises(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client
        .from('workout_exercises')
        .delete()
        .inFilter('id', ids)
        .timeout(_crudTimeout);
  }

  Future<void> addExercise(Map<String, dynamic> data) async {
    await _client
        .from('workout_exercises')
        .insert(data)
        .timeout(_crudTimeout);
  }

  Future<void> addExercises(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    await _client
        .from('workout_exercises')
        .insert(rows)
        .timeout(_crudTimeout);
  }

  /// Rinumera i sort_order dal minimo del gruppo (come reorderExercises web).
  Future<void> reorderExercises(
      List<WorkoutExercise> orderedExercises) async {
    if (orderedExercises.isEmpty) return;
    final minOrder = orderedExercises
        .map((e) => e.sortOrder)
        .reduce((a, b) => a < b ? a : b);
    for (var i = 0; i < orderedExercises.length; i++) {
      await updateExercise(orderedExercises[i].id, {'sort_order': minOrder + i});
    }
  }
}

final workoutRepositoryProvider =
    Provider<WorkoutRepository>((ref) => WorkoutRepository(ref.watch(supabaseProvider)));
