import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'exercise_picker.dart';
import 'workout_providers.dart';

/// Flussi di aggiunta (§8.5): FAB sheet → esercizio singolo / super serie /
/// circuito, con i prompt sequenziali del web.
///
/// [onChanged] è chiamato dopo ogni scrittura (oltre a invalidare
/// `ownPlansProvider`): l'admin lo usa per invalidare `orgPlansProvider` e
/// riusare questi flussi sulla scheda di un cliente.
Future<void> showAddToDay(BuildContext context, WidgetRef ref,
    WorkoutPlan plan, String dayLabel, {VoidCallback? onChanged}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text('Aggiungi al $dayLabel'.toUpperCase(),
                style: AppText.eyebrow),
          ),
          _option(ctx, 'single', '+', brandGradient(ctx),
              'Esercizio singolo', 'Aggiungi un esercizio con riposo'),
          _option(
              ctx,
              'superset',
              'SS',
              const LinearGradient(
                  colors: [Color(0xFFF59E0B), Color(0xFFF97316)]),
              'Super Serie',
              'Due esercizi senza pausa tra loro'),
          _option(
              ctx,
              'circuit',
              'C',
              const LinearGradient(
                  colors: [Color(0xFF06B6D4), Color(0xFF0891B2)]),
              'Circuito',
              'Più esercizi in serie, ripetuti a giri'),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'single':
      await addSingleExercise(context, ref, plan, dayLabel, onChanged: onChanged);
    case 'superset':
      await _addSuperset(context, ref, plan, dayLabel, onChanged: onChanged);
    case 'circuit':
      await _addCircuit(context, ref, plan, dayLabel, onChanged: onChanged);
  }
}

Widget _option(BuildContext ctx, String value, String badge,
    Gradient gradient, String title, String subtitle) {
  return ListTile(
    leading: Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(badge,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 15)),
    ),
    title: Text(title,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
    onTap: () => Navigator.pop(ctx, value),
  );
}

int _nextSortOrder(WorkoutPlan plan) => plan.exercises.isEmpty
    ? 0
    : plan.exercises.map((e) => e.sortOrder).reduce(max) + 1;

String _uuidV4() {
  final rnd = Random.secure();
  String hex(int n) => List.generate(
      n, (_) => rnd.nextInt(16).toRadixString(16)).join();
  return '${hex(8)}-${hex(4)}-4${hex(3)}-'
      '${(8 + rnd.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
}

/// Prompt numerico (come i dialoghi §16.2 del web).
Future<int?> _numericPrompt(BuildContext context, String title,
    {required int defaultValue, String confirmLabel = 'Avanti'}) {
  final controller = TextEditingController(text: '$defaultValue');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(ctx, int.tryParse(controller.text.trim())),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
}

void _toast(BuildContext context, String message, {bool isError = false}) {
  if (isError) {
    AppSnack.error(context, message);
  } else {
    AppSnack.success(context, message);
  }
}

/// Esercizio singolo: serie (3) → ripetizioni (10) → riposo (90).
/// Cardio: nessun prompt (sets 1, reps '20', rest 0).
Future<void> addSingleExercise(BuildContext context, WidgetRef ref,
    WorkoutPlan plan, String dayLabel, {VoidCallback? onChanged}) async {
  final picked = await showExercisePicker(
      context, 'Aggiungi esercizio — $dayLabel');
  if (picked == null || !context.mounted) return;

  int sets = 1;
  String reps = '20';
  int rest = 0;
  if (!picked.isCardio) {
    final s = await _numericPrompt(context, 'Numero di serie:',
        defaultValue: 3);
    if (s == null || !context.mounted) return;
    final r = await _numericPrompt(context, 'Numero di ripetizioni:',
        defaultValue: 10);
    if (r == null || !context.mounted) return;
    final rr = await _numericPrompt(
        context, 'Riposo tra le serie (secondi):',
        defaultValue: 90, confirmLabel: 'Aggiungi');
    if (rr == null || !context.mounted) return;
    sets = s;
    reps = '$r';
    rest = rr;
  }

  try {
    await ref.read(workoutRepositoryProvider).addExercise({
      'plan_id': plan.id,
      'day_label': dayLabel,
      'exercise_name': picked.name,
      'exercise_slug': picked.slug,
      'muscle_group': picked.muscleGroup,
      'sort_order': _nextSortOrder(plan),
      'sets': sets,
      'reps': reps,
      'rest_seconds': rest,
    });
    if (context.mounted) _toast(context, 'Esercizio aggiunto!');
  } catch (_) {
    if (context.mounted) {
      _toast(context, 'Errore nel salvataggio', isError: true);
    }
  }
  ref.invalidate(ownPlansProvider);
  onChanged?.call();
}

/// Super Serie: 2 esercizi → reps ciascuno → serie comuni → riposo finale.
Future<void> _addSuperset(BuildContext context, WidgetRef ref,
    WorkoutPlan plan, String dayLabel, {VoidCallback? onChanged}) async {
  final picks = <PickedExercise>[];
  final reps = <int>[];
  for (var i = 1; i <= 2; i++) {
    final picked = await showExercisePicker(
        context, 'Super Serie — Esercizio $i di 2');
    if (picked == null || !context.mounted) return;
    final r = await _numericPrompt(context, 'Numero di ripetizioni:',
        defaultValue: 10);
    if (r == null || !context.mounted) return;
    picks.add(picked);
    reps.add(r);
  }
  final sets = await _numericPrompt(
      context, 'Numero di serie (per entrambi):',
      defaultValue: 3);
  if (sets == null || !context.mounted) return;
  final rest = await _numericPrompt(
      context, 'Riposo dopo la super serie (secondi):',
      defaultValue: 90, confirmLabel: 'Aggiungi');
  if (rest == null || !context.mounted) return;

  final group = _uuidV4();
  final base = _nextSortOrder(plan);
  try {
    await ref.read(workoutRepositoryProvider).addExercises([
      for (var i = 0; i < 2; i++)
        {
          'plan_id': plan.id,
          'day_label': dayLabel,
          'exercise_name': picks[i].name,
          'exercise_slug': picks[i].slug,
          'muscle_group': picks[i].muscleGroup,
          'sort_order': base + i,
          'sets': sets,
          'reps': '${reps[i]}',
          'rest_seconds': i == 0 ? 0 : rest,
          'superset_group': group,
        }
    ]);
    if (context.mounted) _toast(context, 'Super Serie aggiunta!');
  } catch (_) {
    if (context.mounted) {
      _toast(context, 'Errore nel salvataggio', isError: true);
    }
  }
  ref.invalidate(ownPlansProvider);
  onChanged?.call();
}

/// Circuito: N≥2 esercizi con reps → giri → riposo tra giri (solo ultimo).
Future<void> _addCircuit(BuildContext context, WidgetRef ref,
    WorkoutPlan plan, String dayLabel, {VoidCallback? onChanged}) async {
  final picks = <PickedExercise>[];
  final reps = <String>[];

  while (true) {
    final picked = await showExercisePicker(
        context, 'Circuito — Esercizio ${picks.length + 1}');
    if (picked == null) break;
    if (!context.mounted) return;
    final r = await _numericPrompt(
      context,
      picked.isCardio
          ? 'Durata esercizio cardio (minuti):'
          : 'Ripetizioni per "${picked.name}":',
      defaultValue: picked.isCardio ? 20 : 10,
    );
    if (r == null) continue;
    if (!context.mounted) return;
    picks.add(picked);
    reps.add('$r');

    if (picks.length >= 2) {
      final more = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text([
            for (var i = 0; i < picks.length; i++)
              '${i + 1}. ${picks[i].name} × ${reps[i]}'
          ].join('\n')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('+ Aggiungi esercizio')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Concludi circuito')),
          ],
        ),
      );
      if (more != true) break;
      if (!context.mounted) return;
    }
  }
  if (!context.mounted) return;
  if (picks.length < 2) {
    _toast(context, 'Un circuito deve avere almeno 2 esercizi',
        isError: true);
    return;
  }

  final rounds = await _numericPrompt(
      context, 'Numero di giri del circuito:',
      defaultValue: 3);
  if (rounds == null || !context.mounted) return;
  final rest = await _numericPrompt(
      context, 'Riposo tra un giro e l\'altro (secondi):',
      defaultValue: 90, confirmLabel: 'Aggiungi');
  if (rest == null || !context.mounted) return;

  final group = _uuidV4();
  final base = _nextSortOrder(plan);
  try {
    await ref.read(workoutRepositoryProvider).addExercises([
      for (var i = 0; i < picks.length; i++)
        {
          'plan_id': plan.id,
          'day_label': dayLabel,
          'exercise_name': picks[i].name,
          'exercise_slug': picks[i].slug,
          'muscle_group': picks[i].muscleGroup,
          'sort_order': base + i,
          'sets': rounds,
          'reps': reps[i],
          'rest_seconds': i == picks.length - 1 ? rest : 0,
          'circuit_group': group,
        }
    ]);
    if (context.mounted) _toast(context, 'Circuito aggiunto!');
  } catch (_) {
    if (context.mounted) {
      _toast(context, 'Errore nel salvataggio', isError: true);
    }
  }
  ref.invalidate(ownPlansProvider);
  onChanged?.call();
}

/// Nuovo giorno (§8.3): nome con default "Giorno A/B/C…" → picker del primo
/// esercizio (il giorno nasce col primo esercizio).
Future<void> addDayToScheda(
    BuildContext context, WidgetRef ref, WorkoutPlan plan) async {
  final existing = plan.dayLabels;
  String defaultName = 'Giorno A';
  for (var i = 0; i < 26; i++) {
    final candidate = 'Giorno ${String.fromCharCode(65 + i)}';
    if (!existing.contains(candidate)) {
      defaultName = candidate;
      break;
    }
  }
  final controller = TextEditingController(text: defaultName);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Nome del nuovo giorno:',
          style: TextStyle(fontSize: 17)),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Avanti')),
      ],
    ),
  );
  if (name == null || name.isEmpty || !context.mounted) return;
  if (existing.contains(name)) {
    _toast(context, 'Questo giorno esiste già', isError: true);
    return;
  }
  await addSingleExercise(context, ref, plan, name);
}
