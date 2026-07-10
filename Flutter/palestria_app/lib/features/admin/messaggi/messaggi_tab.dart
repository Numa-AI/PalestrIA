import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Tab Messaggi: composizione di una notifica push ai clienti
/// (edge send-admin-message, mode tutti/giorno/ora).
class MessaggiTab extends ConsumerStatefulWidget {
  const MessaggiTab({super.key});

  @override
  ConsumerState<MessaggiTab> createState() => _MessaggiTabState();
}

class _MessaggiTabState extends ConsumerState<MessaggiTab> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _mode = 'tutti';
  DateTime? _date;
  String? _time;
  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty) {
      AppSnack.error(context, 'Titolo e testo sono obbligatori.');
      return;
    }
    if ((_mode == 'giorno' || _mode == 'ora') && _date == null) {
      AppSnack.error(context, 'Seleziona la data dei destinatari.');
      return;
    }
    if (_mode == 'ora' && (_time == null || _time!.trim().isEmpty)) {
      AppSnack.error(context, 'Seleziona un orario');
      return;
    }
    final confirmed = await _confirmSend();
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    final repo = await ref.read(adminRepositoryProvider.future);
    if (repo == null) {
      setState(() => _sending = false);
      return;
    }
    try {
      final n = await repo.sendMessage(
        title: _title.text.trim(),
        body: _body.text.trim(),
        mode: _mode,
        date: _date == null
            ? null
            : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}',
        time: _mode == 'ora' ? _time : null,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _title.clear();
        _body.clear();
      });
      AppSnack.success(context, 'Messaggio inviato a $n destinatari.');
      ref.invalidate(adminMessagesProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      AppSnack.error(context, 'Errore: $e');
    }
  }

  /// Descrizione leggibile dei destinatari per il dialog di conferma pre-invio.
  String _recipientsLabel() {
    switch (_mode) {
      case 'giorno':
        return _date == null
            ? 'i clienti del giorno selezionato'
            : 'i clienti del ${_date!.day}/${_date!.month}/${_date!.year}';
      case 'ora':
        final when = _date == null
            ? ''
            : ' del ${_date!.day}/${_date!.month}/${_date!.year}'
                '${_time != null && _time!.trim().isNotEmpty ? ' alle ${_time!.trim()}' : ''}';
        return 'i clienti$when';
      default:
        return 'tutti i clienti';
    }
  }

  Future<bool?> _confirmSend() => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Conferma invio'),
          content: Text(
              'Inviare la notifica "${_title.text.trim()}" a ${_recipientsLabel()}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Invia'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final recent = ref.watch(adminMessagesProvider).value ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
      children: [
        const Text('Messaggi', style: AppText.pageTitle),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          radius: AppRadius.cardLg,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Titolo'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _body,
                maxLines: 3,
                maxLength: 200,
                decoration: const InputDecoration(labelText: 'Testo'),
              ),
              const SizedBox(height: AppSpacing.md),
              const Text('Destinatari', style: AppText.eyebrow),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                style: SegmentedButton.styleFrom(
                  selectedBackgroundColor: Theme.of(context).colorScheme.primary,
                  selectedForegroundColor: Colors.white,
                ),
                segments: const [
                  ButtonSegment(value: 'tutti', label: Text('Tutti')),
                  ButtonSegment(value: 'giorno', label: Text('Per giorno')),
                  ButtonSegment(value: 'ora', label: Text('Giorno+ora')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() {
                  _mode = s.first;
                  if ((_mode == 'giorno' || _mode == 'ora') &&
                      _date == null) {
                    _date = DateTime.now();
                  }
                }),
              ),
              if (_mode == 'giorno' || _mode == 'ora') ...[
                const SizedBox(height: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                  icon: const Icon(Icons.calendar_today_outlined, size: 18),
                  label: Text(_date == null
                      ? 'Scegli data'
                      : '${_date!.day}/${_date!.month}/${_date!.year}'),
                ),
              ],
              if (_mode == 'ora') ...[
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Orario (es. 08:00 - 09:20)',
                  ),
                  onChanged: (v) => _time = v.trim(),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send, size: 18),
                label: Text(_sending ? 'Invio...' : 'Invia notifica'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (recent.isNotEmpty) ...[
          const Text('Ultimi messaggi', style: AppText.eyebrow),
          const SizedBox(height: AppSpacing.sm),
          for (final m in recent.take(20))
            AppCard(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((m['title'] as String?) ?? '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13.5)),
                        Text((m['body'] as String?) ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.muted)),
                      ],
                    ),
                  ),
                  StatusPill(
                    label: '${(m['sent_count'] as num?)?.toInt() ?? 0} inviati',
                    background: AppColors.successSurface,
                    foreground: AppColors.green700,
                    dense: true,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
