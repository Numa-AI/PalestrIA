import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/billing_saas.dart';
import '../../../core/data/client_billing_models.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/security/external_url.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Pagamenti cliente: Stripe Connect, listini separati e cambio modello
/// transazionale con tre conferme di sicurezza.
class PaymentsSection extends ConsumerStatefulWidget {
  const PaymentsSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<PaymentsSection> createState() => _PaymentsSectionState();
}

class _PaymentsSectionState extends ConsumerState<PaymentsSection> {
  bool _loading = true;
  bool _saving = false;
  String _model = 'pay_per_session';
  String _loadedModel = 'pay_per_session';
  final _threshold = TextEditingController(text: '0');
  final _grace = TextEditingController(text: '0');
  final _packageLabel = TextEditingController(text: 'Pacchetto 10 ingressi');
  final _packageSessions = TextEditingController(text: '10');
  final _packagePrice = TextEditingController(text: '0');
  final _monthlyPrice = TextEditingController(text: '0');
  final _quarterlyPrice = TextEditingController(text: '0');
  final _annualPrice = TextEditingController(text: '0');
  bool _blockMemb = true;
  bool _blockPkg = true;
  bool _autoDec = true;
  List<Map<String, dynamic>> _slotTypes = [];
  final Map<String, TextEditingController> _prices = {};
  Map<String, dynamic>? _stripe;

  String get _orgId => widget.service.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _threshold,
      _grace,
      _packageLabel,
      _packageSessions,
      _packagePrice,
      _monthlyPrice,
      _quarterlyPrice,
      _annualPrice,
      ..._prices.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(supabaseProvider);
    try {
      final results = await Future.wait<dynamic>([
        client.from('billing_settings').select('*').eq('org_id', _orgId).maybeSingle(),
        client
            .from('slot_types')
            .select('id,key,label,default_price,is_active')
            .eq('org_id', _orgId)
            .order('sort_order'),
        client
            .from('organizations')
            .select('stripe_account_id,stripe_charges_enabled,stripe_account_email')
            .eq('id', _orgId)
            .maybeSingle(),
      ]);
      final billing = results[0] as Map<String, dynamic>?;
      _slotTypes = [
        for (final r in results[1] as List) (r as Map).cast<String, dynamic>(),
      ];
      _stripe = results[2] as Map<String, dynamic>?;
      if (billing != null) {
        _model = effectiveBillingModel(billing);
        _loadedModel = _model;
        _threshold.text = _number(billing['block_unpaid_threshold']);
        _grace.text = _number(billing['grace_days']);
        _packageLabel.text =
            (billing['package_label'] as String?) ?? 'Pacchetto 10 ingressi';
        _packageSessions.text = _number(billing['package_sessions'], fallback: 10);
        _packagePrice.text = _money(billing['package_price']);
        _monthlyPrice.text = _money(billing['membership_monthly_price']);
        _quarterlyPrice.text = _money(billing['membership_quarterly_price']);
        _annualPrice.text = _money(billing['membership_annual_price']);
        _blockMemb = (billing['block_if_membership_expired'] as bool?) ?? true;
        _blockPkg = (billing['block_if_no_package'] as bool?) ?? true;
        _autoDec = (billing['package_auto_decrement'] as bool?) ?? true;
      }
      final cached =
          (widget.service.get('billing_client.prices') as Map?)
              ?.cast<String, dynamic>() ??
          {};
      for (final st in _slotTypes) {
        final value =
            (st['default_price'] as num?)?.toDouble() ??
            (cached[st['key']] as num?)?.toDouble() ??
            0;
        _prices[st['id'] as String] = TextEditingController(
          text: value.toStringAsFixed(2),
        );
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Configurazione non disponibile: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _number(Object? value, {num fallback = 0}) =>
      ((value as num?) ?? fallback).toString();
  String _money(Object? value) =>
      ((value as num?)?.toDouble() ?? 0).toStringAsFixed(2);
  double _parseMoney(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;

  String _label(String model) => clientBillingModels
      .firstWhere((m) => m.$1 == model, orElse: () => (model, model, ''))
      .$2;

  Future<void> _save() async {
    if (_saving) return;
    final client = ref.read(supabaseProvider);
    var confirmed = false;
    if (_model != _loadedModel) {
      final impact = (await client.rpc(
        'get_billing_model_change_impact',
        params: {'p_model': _model},
      )) as Map<String, dynamic>;
      if (!mounted ||
          !await _confirm(
            '1/3 · Cambio modello',
            'Stai passando da “${_label(_loadedModel)}” a “${_label(_model)}”. '
                'Il nuovo modello sarà applicato come predefinito a tutti i clienti.',
            'Continua',
          )) {
        return;
      }
      if (!mounted ||
          !await _confirm(
            '2/3 · Stati da annullare',
            'Saranno annullati ${impact['open_session_balances'] ?? 0} saldi/crediti '
                'a lezione, ${impact['active_packages'] ?? 0} pacchetti, '
                '${impact['active_memberships'] ?? 0} abbonamenti e '
                '${impact['client_overrides'] ?? 0} override cliente.',
            'Continua',
          )) {
        return;
      }
      if (!mounted ||
          !await _confirm(
            '3/3 · Conferma definitiva',
            'Pagamenti già registrati, incassi e statistiche storiche resteranno '
                'invariati. Confermi il cambio del modello?',
            'Conferma cambio',
            destructive: true,
          )) {
        return;
      }
      confirmed = true;
    }

    setState(() => _saving = true);
    try {
      final slotPrices = <String, dynamic>{};
      for (final st in _slotTypes) {
        slotPrices[st['key'] as String] = _parseMoney(
          _prices[st['id'] as String]!,
        );
      }
      final result = (await client.rpc(
        'admin_save_default_billing_model',
        params: {
          'p_model': _model,
          'p_block_unpaid_threshold': _parseMoney(_threshold),
          'p_block_if_membership_expired': _blockMemb,
          'p_block_if_no_package': _blockPkg,
          'p_grace_days': int.tryParse(_grace.text.trim()) ?? 0,
          'p_package_auto_decrement': _autoDec,
          'p_package_label': _packageLabel.text.trim(),
          'p_package_sessions': int.tryParse(_packageSessions.text.trim()) ?? 10,
          'p_package_price': _parseMoney(_packagePrice),
          'p_monthly_price': _parseMoney(_monthlyPrice),
          'p_quarterly_price': _parseMoney(_quarterlyPrice),
          'p_annual_price': _parseMoney(_annualPrice),
          'p_slot_prices': slotPrices,
          'p_expected_current_model': _loadedModel,
          'p_confirm_1': confirmed,
          'p_confirm_2': confirmed,
          'p_confirm_3': confirmed,
        },
      )) as Map<String, dynamic>;
      _loadedModel = _model;
      await widget.service.load();
      if (mounted) {
        AppSnack.success(
          context,
          result['model_changed'] == true
              ? 'Modello aggiornato: ${result['voided_session_balances'] ?? 0} saldi, '
                    '${result['cancelled_packages'] ?? 0} pacchetti e '
                    '${result['cancelled_memberships'] ?? 0} abbonamenti annullati.'
              : 'Pagamenti salvati.',
        );
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(
    String title,
    String message,
    String action, {
    bool destructive = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: AppColors.dangerDark)
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppLoading();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stripeCard(),
        const SizedBox(height: AppSpacing.lg),
        const Text(
          'Modello di pagamento predefinito',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
        const Text(
          'Ogni modello mostra solo le impostazioni che gli appartengono.',
          style: AppText.meta,
        ),
        const SizedBox(height: AppSpacing.sm),
        RadioGroup<String>(
          groupValue: _model,
          onChanged: (v) => setState(() => _model = v ?? _model),
          child: Column(
            children: [
              for (final m in clientBillingModels)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: m.$1,
                  title: Text(
                    m.$2,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(m.$3, style: AppText.meta),
                ),
            ],
          ),
        ),
        const Divider(height: AppSpacing.xl),
        if (_model == 'pay_per_session') _payPerSessionSection(),
        if (_model == 'package') _packageSection(),
        if (isMembershipBillingModel(_model)) _membershipSection(),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio…' : 'Salva pagamenti'),
        ),
      ],
    );
  }

  Widget _payPerSessionSection() => _section(
    'A entrata · listino per lezione',
    'Ogni prenotazione congela il prezzo dello slot. Il credito cliente separa maturato e futuro.',
    [
      TextField(
        controller: _threshold,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Soglia credito scaduto (€, 0 = nessun blocco)',
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      if (_slotTypes.isEmpty)
        const Text('Nessun tipo di slot configurato.', style: AppText.meta)
      else
        for (final st in _slotTypes) _slotPriceRow(st),
    ],
  );

  Widget _packageSection() => _section(
    'Pacchetto · listino',
    'Il pacchetto ha un prezzo dedicato. Nel profilo cliente non compare credito a lezione.',
    [
      TextField(
        controller: _packageLabel,
        maxLength: 120,
        decoration: const InputDecoration(labelText: 'Nome pacchetto'),
      ),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _packageSessions,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Ingressi inclusi'),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: _priceField(_packagePrice, 'Prezzo (€)')),
        ],
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _blockPkg,
        onChanged: (v) => setState(() => _blockPkg = v),
        title: const Text('Blocca senza pacchetto'),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _autoDec,
        onChanged: (v) => setState(() => _autoDec = v),
        title: const Text('Decremento automatico degli ingressi'),
      ),
    ],
  );

  Widget _membershipSection() => _section(
    'Abbonamento · pacchetti per durata',
    'Un solo modello con tre pacchetti di durata: 1 mese, 3 mesi oppure 12 mesi. Nel profilo compare la copertura attiva.',
    [
      _priceField(_monthlyPrice, 'Pacchetto 1 mese (€)'),
      const SizedBox(height: AppSpacing.sm),
      _priceField(_quarterlyPrice, 'Pacchetto 3 mesi (€)'),
      const SizedBox(height: AppSpacing.sm),
      _priceField(_annualPrice, 'Pacchetto 12 mesi (€)'),
      const SizedBox(height: AppSpacing.sm),
      TextField(
        controller: _grace,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'Giorni di tolleranza'),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: _blockMemb,
        onChanged: (v) => setState(() => _blockMemb = v),
        title: const Text('Blocca abbonamento scaduto'),
      ),
    ],
  );

  Widget _section(String title, String description, List<Widget> children) =>
      Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.slate50,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(description, style: AppText.meta),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      );

  Widget _slotPriceRow(Map<String, dynamic> st) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${st['label']}${(st['is_active'] as bool? ?? true) ? '' : ' (disattivo)'}',
          ),
        ),
        SizedBox(
          width: 112,
          child: _priceField(_prices[st['id']]!, 'Prezzo (€)', dense: true),
        ),
      ],
    ),
  );

  Widget _priceField(
    TextEditingController controller,
    String label, {
    bool dense = false,
  }) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: label, isDense: dense),
  );

  Future<void> _connectStripe() async {
    try {
      final enabled = await ref.read(
        featureEnabledProvider('client_online_payments').future,
      );
      if (!enabled) throw Exception('Funzione non disponibile nel piano corrente');
      final res = await ref
          .read(supabaseProvider)
          .functions
          .invoke('stripe-connect', body: {'action': 'start'});
      final url = trustedExternalUri((res.data as Map?)?['url'] as String?);
      if (url == null || !await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Impossibile aprire Stripe');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore collegamento Stripe: $e');
    }
  }

  Future<void> _disconnectStripe() async {
    if (!await _confirm(
      'Scollega Stripe',
      'I clienti non potranno più pagarti online finché non lo ricolleghi.',
      'Scollega',
      destructive: true,
    )) {
      return;
    }
    try {
      await ref
          .read(supabaseProvider)
          .functions
          .invoke('stripe-connect', body: {'action': 'disconnect'});
      if (mounted) AppSnack.success(context, 'Account Stripe scollegato.');
      setState(() => _loading = true);
      await _load();
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
    }
  }

  Widget _stripeCard() {
    final hasAccount = (_stripe?['stripe_account_id'] as String?) != null;
    final active = (_stripe?['stripe_charges_enabled'] as bool?) ?? false;
    final email = (_stripe?['stripe_account_email'] as String?) ?? '';
    return _section('Incassi online · Stripe', 'Collega il tuo account Stripe.', [
      if (hasAccount) ...[
        Text(
          active ? 'Account collegato e attivo.' : 'Onboarding da completare.',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: active ? AppColors.successEmeraldDark : const Color(0xFFB45309),
          ),
        ),
        if (email.isNotEmpty) Text(email, style: AppText.meta),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            if (!active)
              FilledButton(
                onPressed: _connectStripe,
                child: const Text('Completa su Stripe'),
              ),
            if (!active) const SizedBox(width: AppSpacing.sm),
            OutlinedButton(onPressed: _disconnectStripe, child: const Text('Scollega')),
          ],
        ),
      ] else
        FilledButton.icon(
          onPressed: _connectStripe,
          icon: const Icon(Icons.link, size: 18),
          label: const Text('Collega il mio account Stripe'),
        ),
    ]);
  }
}
