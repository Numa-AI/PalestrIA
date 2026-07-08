import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/schedule_admin.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';

const _presetColors = [
  '#8B5CF6', '#22C55E', '#F59E0B', '#EF4444',
  '#3B82F6', '#06B6D4', '#EC4899', '#64748B',
];

/// Apre l'editor (crea/modifica) di un tipo slot come bottom sheet.
Future<void> showSlotTypeEditor(
  BuildContext context,
  WidgetRef ref, {
  Map<String, dynamic>? existing,
  required List<String> existingKeys,
  required int defaultSort,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: _SlotTypeEditor(
        existing: existing,
        existingKeys: existingKeys,
        defaultSort: defaultSort,
      ),
    ),
  );
}

class _SlotTypeEditor extends ConsumerStatefulWidget {
  const _SlotTypeEditor({
    this.existing,
    required this.existingKeys,
    required this.defaultSort,
  });
  final Map<String, dynamic>? existing;
  final List<String> existingKeys;
  final int defaultSort;

  @override
  ConsumerState<_SlotTypeEditor> createState() => _SlotTypeEditorState();
}

class _SlotTypeEditorState extends ConsumerState<_SlotTypeEditor> {
  late final TextEditingController _label;
  late final TextEditingController _capacity;
  late final TextEditingController _price;
  late final TextEditingController _sort;
  late String _color;
  late bool _bookable;
  late bool _active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: (e?['label'] as String?) ?? '');
    _capacity = TextEditingController(
        text: ((e?['default_capacity'] as num?)?.toInt() ?? 1).toString());
    _price = TextEditingController(
        text: ((e?['default_price'] as num?)?.toDouble() ?? 0).toString());
    _sort = TextEditingController(
        text: ((e?['sort_order'] as num?)?.toInt() ?? widget.defaultSort)
            .toString());
    _color = (e?['color'] as String?) ?? '#8B5CF6';
    _bookable = (e?['bookable'] as bool?) ?? true;
    _active = (e?['is_active'] as bool?) ?? true;
  }

  @override
  void dispose() {
    _label.dispose();
    _capacity.dispose();
    _price.dispose();
    _sort.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final label = _label.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (label.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Inserisci un\'etichetta.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = await ref.read(scheduleAdminRepoProvider.future);
      if (repo == null) throw Exception('Non autorizzato.');
      await repo.saveSlotType(
        id: widget.existing?['id'] as String?,
        label: label,
        color: _color,
        capacity: int.tryParse(_capacity.text.trim()) ?? 0,
        price: double.tryParse(_price.text.trim().replaceAll(',', '.')) ?? 0,
        bookable: _bookable,
        active: _active,
        sortOrder: int.tryParse(_sort.text.trim()) ?? 0,
        existingKeys: widget.existingKeys,
      );
      ref.invalidate(allSlotTypesProvider);
      ref.invalidate(scheduleConfigProvider);
      messenger.showSnackBar(SnackBar(
          content: Text(widget.existing == null
              ? 'Tipo creato.'
              : 'Tipo aggiornato.')));
      navigator.pop();
    } catch (e) {
      final dup = e.toString().contains('23505') ||
          RegExp('duplicate|unique', caseSensitive: false).hasMatch(e.toString());
      messenger.showSnackBar(SnackBar(
          content: Text(dup
              ? 'Esiste già un tipo con questa chiave.'
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
            Text(widget.existing == null ? 'Nuovo tipo di slot' : 'Modifica tipo',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                  labelText: 'Etichetta', hintText: 'Personal Training'),
            ),
            const SizedBox(height: AppSpacing.md),
            const Text('Colore',
                style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _presetColors)
                  GestureDetector(
                    onTap: () => setState(() => _color = c),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: OrgBranding.parseHex(c) ?? AppColors.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _color.toLowerCase() == c.toLowerCase()
                                ? Colors.black
                                : Colors.transparent,
                            width: 2.5),
                      ),
                      child: _color.toLowerCase() == c.toLowerCase()
                          ? const Icon(Icons.check, size: 16, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _capacity,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Capienza default'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Prezzo default (€)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _sort,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Ordine'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _bookable,
              onChanged: (v) => setState(() => _bookable = v),
              title: const Text('Prenotabile dai clienti',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Attivo',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: AppSpacing.sm),
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
                        : (widget.existing == null ? 'Crea tipo' : 'Salva')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
