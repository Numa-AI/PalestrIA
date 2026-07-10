/// Modelli workout (tabelle workout_plans / workout_exercises / workout_logs,
/// spec-data §3.7).
class WorkoutPlan {
  const WorkoutPlan({
    required this.id,
    required this.userId,
    required this.name,
    this.startDate,
    this.endDate,
    this.notes,
    this.active = true,
    this.updatedAt,
    this.exercises = const [],
  });

  final String id;
  final String userId;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? notes;
  final bool active;
  final DateTime? updatedAt;
  final List<WorkoutExercise> exercises;

  /// Giorni della scheda nell'ordine del sort_order degli esercizi.
  List<String> get dayLabels {
    final seen = <String>[];
    for (final e in exercises) {
      if (!seen.contains(e.dayLabel)) seen.add(e.dayLabel);
    }
    return seen;
  }

  List<WorkoutExercise> exercisesOf(String day) =>
      exercises.where((e) => e.dayLabel == day).toList();

  static WorkoutPlan fromRow(Map<String, dynamic> row) {
    final exercises =
        ((row['workout_exercises'] as List?) ?? const [])
            .map((e) => WorkoutExercise.fromRow(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return WorkoutPlan(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      name: (row['name'] as String?) ?? '',
      startDate: _date(row['start_date']),
      endDate: _date(row['end_date']),
      notes: row['notes'] as String?,
      active: (row['active'] as bool?) ?? true,
      updatedAt: _date(row['updated_at']),
      exercises: exercises,
    );
  }

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());
}

class WorkoutExercise {
  const WorkoutExercise({
    required this.id,
    required this.planId,
    required this.dayLabel,
    required this.exerciseName,
    this.exerciseSlug,
    this.muscleGroup,
    this.sortOrder = 0,
    this.sets = 3,
    this.reps = '10',
    this.weightKg,
    this.restSeconds = 90,
    this.supersetGroup,
    this.circuitGroup,
    this.notes,
  });

  final String id;
  final String planId;
  final String dayLabel;
  final String exerciseName;
  final String? exerciseSlug;
  final String? muscleGroup;
  final int sortOrder;
  final int sets;
  final String reps;
  final double? weightKg;
  final int restSeconds;
  final String? supersetGroup;
  final String? circuitGroup;
  final String? notes;

  bool get isCardio => (muscleGroup ?? '').toLowerCase() == 'cardio';

  /// Target display: "3 × 10 · 20 kg · 90s pausa" (cardio: "20 min").
  String get targetLabel {
    if (isCardio) return '$reps min';
    final parts = <String>['$sets × $reps'];
    if (weightKg != null && weightKg! > 0) {
      final w = weightKg! == weightKg!.roundToDouble()
          ? weightKg!.toStringAsFixed(0)
          : weightKg!.toStringAsFixed(1);
      parts.add('$w kg');
    }
    if (restSeconds > 0) {
      parts.add(
        restSeconds <= 3 ? '$restSeconds min' : '${restSeconds}s pausa',
      );
    }
    return parts.join(' · ');
  }

  static WorkoutExercise fromRow(Map<String, dynamic> row) => WorkoutExercise(
    id: row['id'] as String,
    planId: row['plan_id'] as String,
    dayLabel: (row['day_label'] as String?) ?? 'Giorno A',
    exerciseName: (row['exercise_name'] as String?) ?? '',
    exerciseSlug: row['exercise_slug'] as String?,
    muscleGroup: row['muscle_group'] as String?,
    sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
    sets: (row['sets'] as num?)?.toInt() ?? 3,
    reps: (row['reps'] as String?) ?? '10',
    weightKg: (row['weight_kg'] as num?)?.toDouble(),
    restSeconds: (row['rest_seconds'] as num?)?.toInt() ?? 90,
    supersetGroup: row['superset_group'] as String?,
    circuitGroup: row['circuit_group'] as String?,
    notes: row['notes'] as String?,
  );
}

class WorkoutLog {
  const WorkoutLog({
    required this.id,
    required this.exerciseId,
    required this.userId,
    required this.logDate,
    required this.setNumber,
    this.repsDone,
    this.weightDone,
    this.restDone,
    this.rpe,
    this.notes,
  });

  final String id;
  final String exerciseId;
  final String userId;

  /// 'YYYY-MM-DD'
  final String logDate;
  final int setNumber;
  final int? repsDone;
  final double? weightDone;
  final int? restDone;
  final int? rpe;
  final String? notes;

  static WorkoutLog fromRow(Map<String, dynamic> row) => WorkoutLog(
    id: row['id'] as String,
    exerciseId: row['exercise_id'] as String,
    userId: row['user_id'] as String,
    logDate: (row['log_date'] as String?) ?? '',
    setNumber: (row['set_number'] as num?)?.toInt() ?? 1,
    repsDone: (row['reps_done'] as num?)?.toInt(),
    weightDone: (row['weight_done'] as num?)?.toDouble(),
    restDone: (row['rest_done'] as num?)?.toInt(),
    rpe: (row['rpe'] as num?)?.toInt(),
    notes: row['notes'] as String?,
  );
}
