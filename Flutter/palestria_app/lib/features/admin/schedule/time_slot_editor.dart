import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/tokens.dart';

/// Apre l'editor (crea/modifica) di una fascia oraria come bottom sheet.
Future<void> showTimeSlotEditor(
  BuildContext context,
  WidgetRef ref, {
  Map<String, dynamic>? existing,
  required int defaultSort,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _TimeSlotEditor(existing: existing, defaultSort: defaultSort),
    ),
  );
}

class _TimeSlotEditor extends ConsumerStatefulWidget {
  const _TimeSlotEditor({this.existing, required this.defaultSort});
  final Map<String, dynamic>? existing;
  final int defaultSort;

  @override
  ConsumerState<_TimeSlotEditor> createState() => _TimeSlotEditorState();
}

class _TimeSlotEditorState extends ConsumerState<_TimeSlotEditor> {
  late TimeOfDay _start;
  late TimeOfDay _end;
  late final TextEditingController _label;
  late final TextEditingController _sort;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _start = _parse((e?['start_time'] as String?) ?? '09:00', 9);
    _end = _parse((e?['end_time'] as String?) ?? '10:00', 10);
    _label = TextEditingController(text: (e?['label'] as String?) ?? '');
    _sort = TextEditingController(
        text: ((e?['sort_order'] as num?)?.toInt() ?? widget.defaultSort)
            .toString());
  }

  static TimeOfDay _parse(String hhmm, int fallbackHour) {
    final parts = hhmm.split(':');
    return TimeOfDay(
      hour: int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? fallbackHour,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0,
    );
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _label.dispose();
    _sort.dispose();
    super.dispose();
  }

  Future<void> _pick(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked != null) {
      setState(() => isStart ? _start = picked : _end = picked);
    }
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final startM = _start.hour * 60 + _start.minute;
    final endM = _end.hour * 60 + _end.minute;
    if (endM <= startM) {
      messenger.showSnackBar(
          const SnackBar(content: Text('La fine deve essere dopo l\'inizio.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) throw Exception('Non autorizzato.');
      await repo.saveTimeSlot(
        id: widget.existing?['id'] as String?,
        start: _fmt(_start),
        end: _fmt(_end),
        label: _label.text,
        sortOrder: int.tryParse(_sort.text.trim()) ?? 0,
      );
      ref.invalidate(allTimeSlotsProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger.showSnackBar(SnackBar(
          content: Text(
              widget.existing == null ? 'Fascia creata.' : 'Fascia aggiornata.')));
      navigator.pop();
    } catch (e) {
      final dup = e.toString().contains('23505') ||
          RegExp('duplicate|unique', caseSensitive: false)
              .hasMatch(e.toString());
      messenger.showSnackBar(SnackBar(
          content: Text(dup
              ? 'Esiste già una fascia con questi orari.'
              : 'Errore nel salvataggio: $e')));
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
                    ? 'Nuova fascia oraria'
                    : 'Modifica fascia',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(child: _timeButton('Inizio', _start, () => _pick(true))),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _timeButton('Fine', _end, () => _pick(false))),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                  labelText: 'Etichetta (opzionale)', hintText: 'Mattina'),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _sort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Ordine'),
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
                    child: Text(_saving
                        ? 'Salvataggio...'
                        : (widget.existing == null ? 'Crea fascia' : 'Salva')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _timeButton(String label, TimeOfDay t, VoidCallback onTap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.access_time, size: 18),
          label: Text(_fmt(t),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
