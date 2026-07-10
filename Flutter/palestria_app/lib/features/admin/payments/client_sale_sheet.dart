import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/data/client_billing_models.dart';
import '../../../core/data/client_operations.dart';
import '../../../core/theme/tokens.dart';

enum ClientSaleKind { package, membership, adjustment }

Future<bool?> showClientSaleSheet(
  BuildContext context,
  WidgetRef ref, {
  AdminClient? client,
  ClientSaleKind initialKind = ClientSaleKind.package,
  bool lockKind = false,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) =>
      _ClientSaleSheet(
        initialClient: client,
        initialKind: initialKind,
        lockKind: lockKind,
      ),
);

class _ClientSaleSheet extends ConsumerStatefulWidget {
  const _ClientSaleSheet({
    required this.initialClient,
    required this.initialKind,
    required this.lockKind,
  });
  final AdminClient? initialClient;
  final ClientSaleKind initialKind;
  final bool lockKind;

  @override
  ConsumerState<_ClientSaleSheet> createState() => _ClientSaleSheetState();
}

class _ClientSaleSheetState extends ConsumerState<_ClientSaleSheet> {
  late ClientSaleKind _kind;
  AdminClient? _client;
  final _label = TextEditingController();
  final _price = TextEditingController();
  final _count = TextEditingController();
  final _note = TextEditingController();
  String _method = 'contanti';
  DateTime? _expires;
  late DateTime _periodStart;
  late DateTime _periodEnd;
  bool _autoRenew = false;
  String _billingPeriod = 'monthly';
  Map<String, dynamic>? _catalog;
  bool _saving = false;
  late String _operationKey;

  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind;
    _client = widget.initialClient;
    final now = DateTime.now();
    _periodStart = DateTime(now.year, now.month, now.day);
    _periodEnd = DateTime(now.year, now.month + 1, now.day);
    _operationKey = ClientOperationsRepository.operationKey(_kind.name);
    _applyDefaults();
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    try {
      final row = await ref
          .read(supabaseProvider)
          .from('billing_settings')
          .select(
            'default_model,default_membership_period,package_label,package_sessions,'
            'package_price,membership_monthly_price,membership_quarterly_price,'
            'membership_annual_price',
          )
          .maybeSingle();
      if (!mounted || row == null) return;
      setState(() {
        _catalog = row;
        if (_kind == ClientSaleKind.membership) {
          _billingPeriod = effectiveBillingModel(row);
          if (!isMembershipBillingModel(_billingPeriod)) {
            _billingPeriod = 'monthly';
          }
        }
        _applyDefaults();
      });
    } catch (_) {}
  }

  void _applyDefaults() {
    switch (_kind) {
      case ClientSaleKind.package:
        _label.text = (_catalog?['package_label'] as String?) ?? 'Pacchetto 10 lezioni';
        _count.text = ((_catalog?['package_sessions'] as num?) ?? 10).toString();
        _price.text = ((_catalog?['package_price'] as num?) ?? 0).toStringAsFixed(2);
      case ClientSaleKind.membership:
        _applyMembershipPeriod();
        _count.clear();
      case ClientSaleKind.adjustment:
        _label.clear();
        _count.clear();
    }
  }

  void _applyMembershipPeriod() {
    final months = billingPeriodMonths(_billingPeriod);
    _label.text = 'Abbonamento · $months ${months == 1 ? 'mese' : 'mesi'}';
    _periodEnd = membershipPeriodEnd(_periodStart, _billingPeriod);
    final value = (_catalog?[billingPeriodPriceColumn(_billingPeriod)] as num?) ?? 0;
    _price.text = value.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _label.dispose();
    _price.dispose();
    _count.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clients =
        ref.watch(adminClientsProvider).value ?? const <AdminClient>[];
    final registered = clients.where((c) => c.userId != null).toList();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .92,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8F7FC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _hero(),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.lockKind)
                    _lockedKindHeader()
                  else
                    _kindSelector(),
                  const SizedBox(height: AppSpacing.lg),
                  DropdownButtonFormField<String>(
                    initialValue: _client?.userId,
                    decoration: _decoration(
                      'Cliente registrato',
                      Icons.person_outline,
                    ),
                    items: [
                      for (final c in registered)
                        DropdownMenuItem(value: c.userId, child: Text(c.name)),
                    ],
                    onChanged: (id) => setState(() {
                      _client = registered
                          .where((c) => c.userId == id)
                          .firstOrNull;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_kind != ClientSaleKind.adjustment) ...[
                    TextField(
                      controller: _label,
                      decoration: _decoration(
                        'Nome commerciale',
                        Icons.sell_outlined,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (_kind == ClientSaleKind.package) ...[
                    TextField(
                      controller: _count,
                      keyboardType: TextInputType.number,
                      decoration: _decoration(
                        'Numero di lezioni',
                        Icons.confirmation_number_outlined,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _dateTile(
                      'Scadenza opzionale',
                      _expires,
                      () => _pickDate(true),
                    ),
                  ],
                  if (_kind == ClientSaleKind.membership) ...[
                    DropdownButtonFormField<String>(
                      key: ValueKey(_billingPeriod),
                      initialValue: _billingPeriod,
                      decoration: _decoration(
                        'Pacchetto abbonamento',
                        Icons.date_range_outlined,
                      ),
                      items: const [
                        DropdownMenuItem(value: 'monthly', child: Text('1 mese')),
                        DropdownMenuItem(value: 'quarterly', child: Text('3 mesi')),
                        DropdownMenuItem(value: 'annual', child: Text('12 mesi')),
                      ],
                      onChanged: (value) => setState(() {
                        _billingPeriod = value ?? 'monthly';
                        _applyMembershipPeriod();
                      }),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: _dateTile(
                            'Inizio',
                            _periodStart,
                            () => _pickDate(false, start: true),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: _dateTile(
                            'Fine',
                            _periodEnd,
                            () => _pickDate(false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _count,
                      keyboardType: TextInputType.number,
                      decoration: _decoration(
                        'Lezioni incluse (vuoto = illimitate)',
                        Icons.event_available_outlined,
                      ),
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _autoRenew,
                      onChanged: (v) => setState(() => _autoRenew = v),
                      title: const Text(
                        'Rinnovo automatico',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Promemoria operativo; nessun addebito automatico senza Stripe.',
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                    decoration: _decoration(
                      _kind == ClientSaleKind.adjustment
                          ? 'Importo (+ addebito, − rimborso)'
                          : 'Importo incassato',
                      Icons.euro,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _method,
                    decoration: _decoration(
                      'Metodo',
                      Icons.account_balance_wallet_outlined,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'contanti',
                        child: Text('Contanti'),
                      ),
                      DropdownMenuItem(
                        value: 'contanti-report',
                        child: Text('Contanti con report'),
                      ),
                      DropdownMenuItem(value: 'carta', child: Text('Carta')),
                      DropdownMenuItem(value: 'iban', child: Text('Bonifico')),
                      DropdownMenuItem(value: 'stripe', child: Text('Stripe')),
                      DropdownMenuItem(
                        value: 'gratuito',
                        child: Text('Gratuito'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _method = v ?? 'contanti'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _note,
                    maxLength: 500,
                    maxLines: 2,
                    decoration: _decoration(
                      _kind == ClientSaleKind.adjustment
                          ? 'Motivo obbligatorio'
                          : 'Nota interna opzionale',
                      Icons.notes_outlined,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      _saving ? 'Registrazione…' : 'Conferma operazione',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero() => Container(
    padding: const EdgeInsets.fromLTRB(22, 14, 14, 20),
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFF4C1D95), Color(0xFF7C3AED)]),
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    child: Column(
      children: [
        Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white38,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.point_of_sale, color: Colors.white),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nuova operazione',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    'Incasso e stato cliente aggiornati insieme',
                    style: TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _kindSelector() => SegmentedButton<ClientSaleKind>(
    segments: const [
      ButtonSegment(
        value: ClientSaleKind.package,
        icon: Icon(Icons.confirmation_number_outlined),
        label: Text('Pacchetto'),
      ),
      ButtonSegment(
        value: ClientSaleKind.membership,
        icon: Icon(Icons.calendar_month_outlined),
        label: Text('Abbonamento'),
      ),
      ButtonSegment(
        value: ClientSaleKind.adjustment,
        icon: Icon(Icons.tune),
        label: Text('Rettifica'),
      ),
    ],
    selected: {_kind},
    showSelectedIcon: false,
    onSelectionChanged: (s) => setState(() {
      _kind = s.first;
      _operationKey = ClientOperationsRepository.operationKey(_kind.name);
      _applyDefaults();
    }),
  );

  Widget _lockedKindHeader() {
    final (icon, title, detail) = switch (_kind) {
      ClientSaleKind.package => (
        Icons.confirmation_number_outlined,
        'Vendita pacchetto',
        'Carnet di ingressi secondo il listino configurato.',
      ),
      ClientSaleKind.membership => (
        Icons.calendar_month_outlined,
        'Vendita abbonamento',
        'Scegli un pacchetto da 1, 3 oppure 12 mesi.',
      ),
      ClientSaleKind.adjustment => (
        Icons.tune,
        'Rettifica contabile',
        'Registra una correzione motivata nel ledger.',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE7E2F2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF7C3AED)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                Text(detail, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFE7E2F2)),
    ),
  );

  Widget _dateTile(String label, DateTime? date, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7E2F2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_outlined, color: Color(0xFF7C3AED)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
                Text(
                  date == null
                      ? 'Nessuna'
                      : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> _pickDate(bool expiry, {bool start = false}) async {
    final initial = expiry
        ? (_expires ?? DateTime.now().add(const Duration(days: 90)))
        : (start ? _periodStart : _periodEnd);
    final value = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: expiry ? DateTime.now() : DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 10),
    );
    if (value == null) return;
    setState(() {
      if (expiry) {
        _expires = value;
      } else if (start) {
        _periodStart = value;
        if (_kind == ClientSaleKind.membership) {
          _periodEnd = membershipPeriodEnd(value, _billingPeriod);
        }
      } else {
        _periodEnd = value;
      }
    });
  }

  Future<void> _save() async {
    final client = _client;
    final price = double.tryParse(_price.text.trim().replaceAll(',', '.'));
    if (client?.userId == null) {
      return _error('Seleziona un cliente registrato.');
    }
    final userId = client!.userId!;
    if (price == null ||
        !price.isFinite ||
        (_kind != ClientSaleKind.adjustment && price < 0) ||
        price == 0 && _kind == ClientSaleKind.adjustment) {
      return _error('Inserisci un importo valido.');
    }
    if (_kind == ClientSaleKind.adjustment && _note.text.trim().isEmpty) {
      return _error('Indica il motivo della rettifica.');
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(clientOperationsRepositoryProvider);
      switch (_kind) {
        case ClientSaleKind.package:
          final sessions = int.tryParse(_count.text.trim());
          if (sessions == null || sessions <= 0) {
            return _error('Numero di lezioni non valido.');
          }
          await repo.sellPackage(
            userId: userId,
            label: _label.text.trim(),
            sessions: sessions,
            price: price,
            method: _method,
            expiresAt: _expires,
            note: _note.text.trim(),
            idempotencyKey: _operationKey,
          );
        case ClientSaleKind.membership:
          if (_periodEnd.isBefore(_periodStart)) {
            return _error('La data di fine precede quella di inizio.');
          }
          final quota = _count.text.trim().isEmpty
              ? null
              : int.tryParse(_count.text.trim());
          if (_count.text.trim().isNotEmpty && (quota == null || quota <= 0)) {
            return _error('Quota lezioni non valida.');
          }
          await repo.sellMembership(
            userId: userId,
            label: _label.text.trim(),
            price: price,
            periodStart: _periodStart,
            periodEnd: _periodEnd,
            lessonsQuota: quota,
            method: _method,
            autoRenew: _autoRenew,
            billingPeriod: _billingPeriod,
            note: _note.text.trim(),
            idempotencyKey: _operationKey,
          );
        case ClientSaleKind.adjustment:
          await repo.recordAdjustment(
            userId: userId,
            amount: price,
            method: _method,
            note: _note.text.trim(),
            idempotencyKey: _operationKey,
          );
      }
      ref.invalidate(clientFinancialSummaryProvider(userId));
      ref.invalidate(monthPaymentsProvider);
      ref.invalidate(statsPaymentsProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _error('Operazione non riuscita: ${_friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _error(String message) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: AppColors.dangerDark),
  );

  String _friendlyError(Object error) {
    final text = error.toString();
    const known = {
      'invalid_expiry': 'la scadenza è già trascorsa',
      'client_not_found_or_archived': 'cliente non disponibile o archiviato',
      'invalid_period': 'periodo non valido',
      'refund_exceeds_payment': 'il rimborso supera il pagamento originale',
    };
    for (final entry in known.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return text;
  }
}
