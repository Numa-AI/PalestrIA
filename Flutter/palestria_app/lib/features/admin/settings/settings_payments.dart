import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/billing_saas.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/security/external_url.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Sezione "Pagamenti cliente" (port di _settRenderPayments §4): Stripe Connect
/// (edge `stripe-connect`), modello di pagamento predefinito (billing_settings),
/// blocco prenotazioni per pagamenti, listino prezzi per tipo di slot
/// (`slot_types.default_price` + `org_settings billing_client.prices`).
class PaymentsSection extends ConsumerStatefulWidget {
  const PaymentsSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<PaymentsSection> createState() => _PaymentsSectionState();
}

const _models = [
  ('pay_per_session', '🎟️ A entrata', 'Il cliente paga ogni singola lezione.'),
  ('monthly', '📆 Mensile', 'Abbonamento mensile a tariffa fissa.'),
  ('package', '🎫 Pacchetto', 'Carnet di ingressi prepagato.'),
  ('free', '🎁 Gratuito', 'Nessun pagamento richiesto.'),
];

class _PaymentsSectionState extends ConsumerState<PaymentsSection> {
  bool _loading = true;
  String _model = 'pay_per_session';
  final _threshold = TextEditingController(text: '0');
  final _grace = TextEditingController(text: '0');
  bool _blockMemb = true;
  bool _blockPkg = true;
  bool _autoDec = true;
  List<Map<String, dynamic>> _slotTypes = [];
  final Map<String, TextEditingController> _prices = {};
  Map<String, dynamic>? _stripe;
  bool _saving = false;

  String get _orgId => widget.service.orgId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _threshold.dispose();
    _grace.dispose();
    for (final c in _prices.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final client = ref.read(supabaseProvider);
    try {
      final results = await Future.wait([
        client
            .from('billing_settings')
            .select('*')
            .eq('org_id', _orgId)
            .maybeSingle(),
        client
            .from('slot_types')
            .select('id,key,label,default_price,is_active')
            .eq('org_id', _orgId)
            .order('sort_order'),
        client
            .from('organizations')
            .select(
              'stripe_account_id,stripe_charges_enabled,stripe_account_email',
            )
            .eq('id', _orgId)
            .maybeSingle(),
      ]);
      final billing = results[0] as Map<String, dynamic>?;
      _slotTypes = [
        for (final r in (results[1] as List))
          (r as Map).cast<String, dynamic>(),
      ];
      _stripe = results[2] as Map<String, dynamic>?;
      if (billing != null) {
        _model = (billing['default_model'] as String?) ?? 'pay_per_session';
        _threshold.text = ((billing['block_unpaid_threshold'] as num?) ?? 0)
            .toString();
        _grace.text = ((billing['grace_days'] as num?) ?? 0).toString();
        _blockMemb = (billing['block_if_membership_expired'] as bool?) ?? true;
        _blockPkg = (billing['block_if_no_package'] as bool?) ?? true;
        _autoDec = (billing['package_auto_decrement'] as bool?) ?? true;
      }
      final pricesCache =
          (widget.service.get('billing_client.prices') as Map?)
              ?.cast<String, dynamic>() ??
          {};
      for (final st in _slotTypes) {
        final key = st['key'] as String;
        final price =
            (st['default_price'] as num?)?.toDouble() ??
            (pricesCache[key] as num?)?.toDouble() ??
            0;
        _prices[st['id'] as String] = TextEditingController(
          text: price.toStringAsFixed(2),
        );
      }
    } catch (_) {
      // offline/errore: mostra comunque il form coi default
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _connectStripe() async {
    try {
      final enabled = await ref.read(
        featureEnabledProvider('client_online_payments').future,
      );
      if (!enabled) {
        throw Exception(
          'Pagamenti online non disponibili per il piano corrente',
        );
      }
      final res = await ref
          .read(supabaseProvider)
          .functions
          .invoke('stripe-connect', body: {'action': 'start'});
      final url = trustedExternalUri((res.data as Map?)?['url'] as String?);
      if (url == null) throw Exception('URL di collegamento non valido');
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) throw Exception('Impossibile aprire Stripe');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore collegamento Stripe: $e');
    }
  }

  Future<void> _disconnectStripe() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Scollega Stripe'),
        content: const Text(
          'Scollegare il tuo account Stripe? I clienti non potranno più '
          'pagarti online finché non lo ricolleghi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Scollega'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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

  Future<void> _save() async {
    setState(() => _saving = true);
    final client = ref.read(supabaseProvider);
    try {
      await client.from('billing_settings').upsert({
        'org_id': _orgId,
        'default_model': _model,
        'block_unpaid_threshold': double.tryParse(_threshold.text.trim()) ?? 0,
        'block_if_membership_expired': _blockMemb,
        'block_if_no_package': _blockPkg,
        'grace_days': int.tryParse(_grace.text.trim()) ?? 0,
        'package_auto_decrement': _autoDec,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'org_id');

      final pricesMap = <String, dynamic>{};
      for (final st in _slotTypes) {
        final id = st['id'] as String;
        final key = st['key'] as String;
        final val = double.tryParse(_prices[id]!.text.trim()) ?? 0;
        pricesMap[key] = val;
        await client
            .from('slot_types')
            .update({'default_price': val})
            .eq('id', id)
            .eq('org_id', _orgId);
      }
      await widget.service.set('billing_client.prices', pricesMap);
      if (mounted) AppSnack.success(context, 'Pagamenti salvati.');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: AppLoading(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _stripeCard(),
        const SizedBox(height: AppSpacing.lg),
        const Text(
          'Modello di pagamento predefinito',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
        ),
        const Text(
          'Applicato di default ai nuovi clienti (override per-cliente).',
          style: AppText.meta,
        ),
        const SizedBox(height: AppSpacing.sm),
        RadioGroup<String>(
          groupValue: _model,
          onChanged: (v) => setState(() => _model = v ?? _model),
          child: Column(
            children: [
              for (final m in _models)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: m.$1,
                  title: Text(
                    m.$2,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(m.$3, style: AppText.meta),
                ),
            ],
          ),
        ),
        const Divider(height: AppSpacing.lg),
        const Text(
          'Blocco prenotazioni per pagamenti',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _threshold,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Soglia debito massimo (€, 0 = nessun blocco)',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _grace,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Giorni di tolleranza (grace)',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _blockMemb,
          onChanged: (v) => setState(() => _blockMemb = v),
          title: const Text(
            'Blocca se abbonamento scaduto',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _blockPkg,
          onChanged: (v) => setState(() => _blockPkg = v),
          title: const Text(
            'Blocca se pacchetto esaurito',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoDec,
          onChanged: (v) => setState(() => _autoDec = v),
          title: const Text(
            'Decremento automatico pacchetto',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
        const Divider(height: AppSpacing.lg),
        const Text(
          'Listino prezzi per tipo di slot',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_slotTypes.isEmpty)
          const Text(
            'Nessun tipo di slot configurato. Aggiungili da Gestione Orari.',
            style: AppText.meta,
          )
        else
          for (final st in _slotTypes)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${st['label']}${(st['is_active'] as bool? ?? true) ? '' : ' (disattivo)'}',
                      style: const TextStyle(fontSize: 13.5),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _prices[st['id']],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        prefixText: '€ ',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva pagamenti'),
        ),
      ],
    );
  }

  Widget _stripeCard() {
    final hasAcct = (_stripe?['stripe_account_id'] as String?) != null;
    final chOk = (_stripe?['stripe_charges_enabled'] as bool?) ?? false;
    final email = (_stripe?['stripe_account_email'] as String?) ?? '';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.slate50,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '🔗 Incassi online — Stripe',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          const Text(
            'Collega il TUO account Stripe: i pagamenti dei clienti arrivano '
            'direttamente a te.',
            style: AppText.meta,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (hasAcct) ...[
            Text(
              chOk
                  ? '✅ Account collegato e attivo.'
                  : '⏳ Account collegato — onboarding da completare su Stripe.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: chOk
                    ? AppColors.successEmeraldDark
                    : const Color(0xFFB45309),
              ),
            ),
            if (email.isNotEmpty) Text(email, style: AppText.meta),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                if (!chOk)
                  FilledButton(
                    onPressed: _connectStripe,
                    child: const Text('Completa su Stripe'),
                  ),
                if (!chOk) const SizedBox(width: AppSpacing.sm),
                OutlinedButton(
                  onPressed: _disconnectStripe,
                  child: const Text('Scollega'),
                ),
              ],
            ),
          ] else
            FilledButton.icon(
              onPressed: _connectStripe,
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Collega il mio account Stripe'),
            ),
        ],
      ),
    );
  }
}
