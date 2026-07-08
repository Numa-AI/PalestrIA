import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_repository.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/theme/tokens.dart';
import '../../client/booking/booking_providers.dart';

/// Picker cliente per aggiungere una prenotazione allo slot (spec-admin §3.5).
Future<bool?> showAddParticipantSheet(
    BuildContext context, WidgetRef ref, DaySlot slot, DateTime day) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddParticipantSheet(slot: slot, day: day),
  );
}

class _AddParticipantSheet extends ConsumerStatefulWidget {
  const _AddParticipantSheet({required this.slot, required this.day});

  final DaySlot slot;
  final DateTime day;

  @override
  ConsumerState<_AddParticipantSheet> createState() =>
      _AddParticipantSheetState();
}

class _AddParticipantSheetState extends ConsumerState<_AddParticipantSheet> {
  final _search = TextEditingController();
  String _query = '';
  AdminClient? _selected;
  bool _booking = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients = ref.watch(adminClientsProvider).value ?? const [];

    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _selected == null
              ? _searchView(clients)
              : _confirmView(_selected!),
        ),
      ),
    );
  }

  Widget _searchView(List<AdminClient> clients) {
    final q = _query.trim().toLowerCase();
    final results = q.isEmpty
        ? const <AdminClient>[]
        : clients
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                (c.email ?? '').toLowerCase().contains(q))
            .take(10)
            .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('AGGIUNGI UNA PRENOTAZIONE', style: AppText.eyebrow),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _search,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
          decoration: const InputDecoration(
            hintText: 'Cerca cliente…',
            prefixIcon: Icon(Icons.search, size: 20),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 240,
          child: q.isEmpty
              ? const SizedBox.shrink()
              : results.isEmpty
                  ? const Center(
                      child: Text('Nessun cliente trovato',
                          style: TextStyle(color: Color(0xFF999999))))
                  : ListView(
                      children: [
                        for (final c in results)
                          ListTile(
                            title: Text(c.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(c.email ?? c.whatsapp ?? '',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => setState(() => _selected = c),
                          ),
                      ],
                    ),
        ),
      ],
    );
  }

  Widget _confirmView(AdminClient client) {
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Indietro'),
            ),
          ],
        ),
        Text(client.name,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w800)),
        Text(client.email ?? client.whatsapp ?? '', style: AppText.meta),
        const SizedBox(height: AppSpacing.lg),
        Text(
            'Slot: ${config.slotName(widget.slot.slotType)} · ${widget.slot.time}',
            style: AppText.meta),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          onPressed: _booking ? null : () => _book(client),
          child: Text(_booking ? 'Prenotazione...' : 'Conferma prenotazione'),
        ),
      ],
    );
  }

  Future<void> _book(AdminClient client) async {
    setState(() => _booking = true);
    final repo = await ref.read(adminRepositoryProvider.future);
    final slug = await ref.read(orgSlugProvider.future);
    if (repo == null) {
      setState(() => _booking = false);
      return;
    }
    final dateStr = OrgScheduleConfig.localDateStr(widget.day);
    final error = await repo.bookForClient(
      orgSlug: slug,
      date: dateStr,
      time: widget.slot.time,
      name: client.name,
      email: client.email ?? '',
      whatsapp: client.whatsapp,
      dateDisplay: dateDisplayOf(widget.day),
      forUserId: client.userId,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Prenotazione aggiunta per ${client.name}')));
    } else {
      setState(() => _booking = false);
      final msg = error == 'slot_full'
          ? 'Slot pieno: aggiungi un posto extra, poi riprova.'
          : '⚠️ Errore: prenotazione non riuscita. Riprova.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }
}
