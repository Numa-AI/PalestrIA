import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/client_operations.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

enum ClientBalanceOperation { payment, credit, debt }

Future<bool?> showClientBalanceSheet(
  BuildContext context, {
  required ClientBalanceOperation operation,
  String? initialUserId,
  double? initialAmount,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => _ClientBalanceSheet(
    operation: operation,
    initialUserId: initialUserId,
    initialAmount: initialAmount,
  ),
);

class _ClientBalanceSheet extends ConsumerStatefulWidget {
  const _ClientBalanceSheet({
    required this.operation,
    this.initialUserId,
    this.initialAmount,
  });

  final ClientBalanceOperation operation;
  final String? initialUserId;
  final double? initialAmount;

  @override
  ConsumerState<_ClientBalanceSheet> createState() =>
      _ClientBalanceSheetState();
}

class _ClientBalanceSheetState extends ConsumerState<_ClientBalanceSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  final _note = TextEditingController();
  String? _userId;
  String _method = 'contanti';
  bool _saving = false;
  late final String _operationKey;

  @override
  void initState() {
    super.initState();
    _userId = widget.initialUserId;
    _operationKey = ClientOperationsRepository.operationKey(
      'balance-${widget.operation.name}',
    );
    _amount = TextEditingController(
      text: widget.initialAmount == null
          ? ''
          : widget.initialAmount!.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  String get _title => switch (widget.operation) {
    ClientBalanceOperation.payment => 'Incassa saldo',
    ClientBalanceOperation.credit => 'Aggiungi credito',
    ClientBalanceOperation.debt => 'Aggiungi debito',
  };

  String get _operation => switch (widget.operation) {
    ClientBalanceOperation.payment => 'payment',
    ClientBalanceOperation.credit => 'credit',
    ClientBalanceOperation.debt => 'debt',
  };

  @override
  Widget build(BuildContext context) {
    final profilesAsync = ref.watch(adminProfilesProvider);
    final profiles = profilesAsync.value
            ?.where((profile) => !profile.isArchived)
            .toList() ??
        const <AdminProfile>[];
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(_title, style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.operation == ClientBalanceOperation.debt
                  ? 'Aggiunge un importo dovuto al conto del cliente.'
                  : 'Il credito sarà scalato automaticamente all’inizio delle lezioni.',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: profiles.any((p) => p.id == _userId) ? _userId : null,
              decoration: const InputDecoration(labelText: 'Cliente'),
              items: [
                for (final profile in profiles)
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(profile.name),
                  ),
              ],
              onChanged: _saving ? null : (value) => _userId = value,
              validator: (value) => value == null ? 'Seleziona un cliente' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Importo (€)'),
              validator: (value) {
                final amount = double.tryParse((value ?? '').replaceAll(',', '.'));
                return amount == null || amount <= 0 ? 'Importo non valido' : null;
              },
            ),
            if (widget.operation != ClientBalanceOperation.debt) ...[
              const SizedBox(height: AppSpacing.md),
              DropdownButtonFormField<String>(
                initialValue: _method,
                decoration: const InputDecoration(labelText: 'Metodo'),
                items: const [
                  DropdownMenuItem(value: 'contanti', child: Text('Contanti')),
                  DropdownMenuItem(
                    value: 'contanti-report',
                    child: Text('Contanti con Report'),
                  ),
                  DropdownMenuItem(value: 'carta', child: Text('Carta')),
                  DropdownMenuItem(value: 'iban', child: Text('Bonifico')),
                  DropdownMenuItem(value: 'stripe', child: Text('Stripe')),
                  DropdownMenuItem(
                    value: 'gratuito',
                    child: Text('Credito omaggio (non fatturato)'),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _method = value ?? 'contanti'),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _note,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Nota',
                hintText: 'Motivo dell’operazione',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Salvataggio…' : 'Conferma'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(clientOperationsRepositoryProvider).recordBalanceOperation(
            userId: _userId!,
            operation: _operation,
            amount: double.parse(_amount.text.replaceAll(',', '.')),
            method: widget.operation == ClientBalanceOperation.debt
                ? null
                : _method,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            idempotencyKey: _operationKey,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        AppSnack.error(context, 'Operazione non registrata: $error');
        setState(() => _saving = false);
      }
    }
  }
}
