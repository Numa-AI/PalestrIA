import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/workout_repository.dart';
import '../../../core/models/workout.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'schede_providers.dart';

/// Editor esercizio lato admin (crea/modifica) come bottom sheet. Riusa
/// `WorkoutRepository` (CRUD per-id, non user-scoped) per editare la scheda di
/// un cliente. Per un nuovo esercizio passa [planId]+[dayLabel]+[sortOrder].
Future<void> showExerciseEditSheet(
  BuildContext context,
  WidgetRef ref, {
  WorkoutExercise? existing,
  String? planId,
  String? dayLabel,
  int sortOrder = 0,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.modalLg),
      ),
    ),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _ExerciseEditSheet(
        existing: existing,
        planId: planId,
        dayLabel: dayLabel,
        sortOrder: sortOrder,
      ),
    ),
  );
}

class _ExerciseEditSheet extends ConsumerStatefulWidget {
  const _ExerciseEditSheet({
    this.existing,
    this.planId,
    this.dayLabel,
    required this.sortOrder,
  });
  final WorkoutExercise? existing;
  final String? planId;
  final String? dayLabel;
  final int sortOrder;

  @override
  ConsumerState<_ExerciseEditSheet> createState() => _ExerciseEditSheetState();
}

class _ExerciseEditSheetState extends ConsumerState<_ExerciseEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _sets;
  late final TextEditingController _reps;
  late final TextEditingController _weight;
  late final TextEditingController _rest;
  late final TextEditingController _notes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.exerciseName ?? '');
    _sets = TextEditingController(text: (e?.sets ?? 3).toString());
    _reps = TextEditingController(text: e?.reps ?? '10');
    _weight = TextEditingController(
      text: (e?.weightKg == null || e?.weightKg == 0)
          ? ''
          : (e!.weightKg! == e.weightKg!.roundToDouble()
                ? e.weightKg!.toStringAsFixed(0)
                : e.weightKg!.toStringAsFixed(1)),
    );
    _rest = TextEditingController(text: (e?.restSeconds ?? 90).toString());
    _notes = TextEditingController(text: e?.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _sets, _reps, _weight, _rest, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final navigator = Navigator.of(context);
    if (name.isEmpty) {
      AppSnack.error(context, 'Inserisci il nome dell\'esercizio.');
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(workoutRepositoryProvider);
      final weight = _weight.text.trim().isEmpty
          ? null
          : double.tryParse(_weight.text.trim().replaceAll(',', '.'));
      final fields = {
        'exercise_name': name,
        'sets': int.tryParse(_sets.text.trim()) ?? 3,
        'reps': _reps.text.trim().isEmpty ? '10' : _reps.text.trim(),
        'weight_kg': weight,
        'rest_seconds': int.tryParse(_rest.text.trim()) ?? 90,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      };
      if (widget.existing != null) {
        await repo.updateExercise(widget.existing!.id, fields);
      } else {
        await repo.addExercise({
          'plan_id': widget.planId,
          'day_label': widget.dayLabel,
          'sort_order': widget.sortOrder,
          ...fields,
        });
      }
      ref.invalidate(orgPlansProvider);
      if (mounted) {
        AppSnack.success(
          context,
          widget.existing == null
              ? 'Esercizio aggiunto.'
              : 'Esercizio aggiornato.',
        );
      }
      navigator.pop();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore nel salvataggio: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing == null
                  ? 'Nuovo esercizio${widget.dayLabel != null ? ' · ${widget.dayLabel}' : ''}'
                  : 'Modifica esercizio',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nome esercizio'),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _num(_sets, 'Serie')),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _num(_reps, 'Ripetizioni', number: false)),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _num(_weight, 'Peso (kg)', number: false)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _num(_rest, 'Riposo (s)')),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Note (opzionale)'),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annulla'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving
                          ? 'Salvataggio...'
                          : (widget.existing == null ? 'Aggiungi' : 'Salva'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _num(TextEditingController c, String label, {bool number = true}) =>
      TextField(
        controller: c,
        keyboardType: number
            ? TextInputType.number
            : const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      );
}
