import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/billing_saas.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import 'settings_company.dart';
import 'settings_payments.dart';
import 'settings_prefs.dart';
import 'settings_security.dart';
import 'settings_staff.dart';

/// Fusi orari IANA proposti per la Localizzazione (scelta vincolata: evita
/// valori digitati a mano che romperebbero i calcoli DST lato server).
const _timezoneOptions = [
  'Europe/Rome',
  'Europe/London',
  'Europe/Paris',
  'Europe/Madrid',
  'Europe/Berlin',
  'Europe/Lisbon',
  'Europe/Zurich',
  'Europe/Athens',
  'America/New_York',
  'America/Los_Angeles',
  'UTC',
];

const _currencyOptions = ['EUR', 'USD', 'GBP', 'CHF'];
const _languageOptions = ['it', 'en', 'fr', 'de', 'es'];
const _dateFormatOptions = ['DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD'];

/// Tab Impostazioni org (spec-admin §12). Versione con le sezioni principali:
/// Branding, Localizzazione, Pagamenti cliente, e Billing SaaS (Stripe web).
class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(orgSettingsProvider);

    return settingsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore: $e',
        onRetry: () => ref.invalidate(orgSettingsProvider),
      ),
      data: (service) {
        if (service == null) {
          return const AppEmptyState(
            title: 'Impostazioni non disponibili.',
            icon: Icons.settings_outlined,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            100,
          ),
          children: [
            _section('🎨 Branding', [_BrandingSection(service: service)]),
            _section('🌍 Localizzazione', [
              _DropdownSetting(
                service: service,
                settingKey: 'locale.timezone',
                label: 'Fuso orario',
                defaultValue: 'Europe/Rome',
                options: _timezoneOptions,
              ),
              _DropdownSetting(
                service: service,
                settingKey: 'locale.currency',
                label: 'Valuta',
                defaultValue: 'EUR',
                options: _currencyOptions,
              ),
              _DropdownSetting(
                service: service,
                settingKey: 'locale.language',
                label: 'Lingua',
                defaultValue: 'it',
                options: _languageOptions,
                optionLabels: const {
                  'it': 'Italiano',
                  'en': 'English',
                  'fr': 'Français',
                  'de': 'Deutsch',
                  'es': 'Español',
                },
              ),
              _DropdownSetting(
                service: service,
                settingKey: 'locale.date_format',
                label: 'Formato data',
                defaultValue: 'DD/MM/YYYY',
                options: _dateFormatOptions,
              ),
              _FirstDaySetting(service: service),
            ]),
            _section('🏢 Dati azienda & fiscali', [
              CompanySection(service: service),
            ]),
            _section('💳 Pagamenti cliente', [
              PaymentsSection(service: service),
            ]),
            _section('🛡️ Policy prenotazione', [
              PolicySection(service: service),
            ]),
            _section('🔔 Notifiche', [NotifSection(service: service)]),
            _section('📜 GDPR & Privacy', [GdprSection(service: service)]),
            _section('🧩 Funzionalità', [FeaturesSection(service: service)]),
            _section('👥 Staff / Membri', [StaffSection(service: service)]),
            _section('⚠️ Sicurezza / Manutenzione', [
              SecuritySection(service: service),
            ]),
            _section('⭐ Abbonamento PalestrIA', [const _BillingSaasSection()]),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) => AppCard(
    margin: const EdgeInsets.only(bottom: AppSpacing.lg),
    radius: AppRadius.cardLg,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: AppColors.navy,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        ...children,
      ],
    ),
  );
}

class _BrandingSection extends ConsumerStatefulWidget {
  const _BrandingSection({required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<_BrandingSection> createState() => _BrandingSectionState();
}

class _BrandingSectionState extends ConsumerState<_BrandingSection> {
  late final TextEditingController _studioName;
  late final TextEditingController _pwaName;
  late final TextEditingController _homeDuration;
  late final TextEditingController _logoUrl;
  late final TextEditingController _faviconUrl;
  late final TextEditingController _primaryColor;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _studioName = TextEditingController(
      text: widget.service.getString('branding.studio_name', ''),
    );
    _pwaName = TextEditingController(
      text: widget.service.getString('branding.pwa_name', ''),
    );
    _homeDuration = TextEditingController(
      text: widget.service.getString('branding.home_duration', ''),
    );
    _logoUrl = TextEditingController(
      text: widget.service.getString('branding.logo_url', ''),
    );
    _faviconUrl = TextEditingController(
      text: widget.service.getString('branding.favicon_url', ''),
    );
    _primaryColor = TextEditingController(
      text: widget.service.getString('branding.primary_color', '#8B5CF6'),
    );
  }

  @override
  void dispose() {
    _studioName.dispose();
    _pwaName.dispose();
    _homeDuration.dispose();
    _logoUrl.dispose();
    _faviconUrl.dispose();
    _primaryColor.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.service.set('branding.studio_name', _studioName.text.trim());
      await widget.service.set('branding.pwa_name', _pwaName.text.trim());
      await widget.service.set(
        'branding.home_duration',
        _homeDuration.text.trim(),
      );
      await widget.service.set('branding.logo_url', _logoUrl.text.trim());
      await widget.service.set(
        'branding.favicon_url',
        _faviconUrl.text.trim(),
      );
      await widget.service.set(
        'branding.primary_color',
        _primaryColor.text.trim(),
      );
      final parsed = OrgBranding.parseHex(_primaryColor.text.trim());
      if (parsed != null) {
        await ref
            .read(orgBrandingProvider.notifier)
            .apply(widget.service.currentBranding());
      }
      if (mounted) AppSnack.success(context, 'Branding salvato.');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore nel salvataggio: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _studioName,
          decoration: const InputDecoration(labelText: 'Nome studio'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _pwaName,
          decoration: const InputDecoration(
            labelText: 'Nome PWA (app installata)',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _homeDuration,
          decoration: const InputDecoration(
            labelText: 'Durata sessione (home)',
            hintText: 'Es. 80 minuti',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _logoUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL logo'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _faviconUrl,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(labelText: 'URL favicon'),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _primaryColor,
          decoration: const InputDecoration(
            labelText: 'Colore primario (hex)',
            hintText: '#8B5CF6',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva branding'),
        ),
      ],
    );
  }
}

/// Impostazione a scelta vincolata (Localizzazione): dropdown invece di testo
/// libero, salva subito la chiave `org_settings` al cambio.
class _DropdownSetting extends ConsumerStatefulWidget {
  const _DropdownSetting({
    required this.service,
    required this.settingKey,
    required this.label,
    required this.defaultValue,
    required this.options,
    this.optionLabels = const {},
  });

  final OrgSettingsService service;
  final String settingKey;
  final String label;
  final String defaultValue;
  final List<String> options;
  final Map<String, String> optionLabels;

  @override
  ConsumerState<_DropdownSetting> createState() => _DropdownSettingState();
}

class _DropdownSettingState extends ConsumerState<_DropdownSetting> {
  late String _value;

  @override
  void initState() {
    super.initState();
    final current = widget.service.getString(
      widget.settingKey,
      widget.defaultValue,
    );
    _value = widget.options.contains(current) ? current : widget.defaultValue;
  }

  Future<void> _onChanged(String? v) async {
    if (v == null || v == _value) return;
    final previous = _value;
    setState(() => _value = v);
    try {
      await widget.service.set(widget.settingKey, v);
      if (mounted) AppSnack.success(context, 'Impostazione salvata.');
    } catch (e) {
      if (mounted) {
        setState(() => _value = previous);
        AppSnack.error(context, 'Errore: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: DropdownButtonFormField<String>(
        initialValue: _value,
        decoration: InputDecoration(labelText: widget.label),
        items: [
          for (final o in widget.options)
            DropdownMenuItem(
              value: o,
              child: Text(widget.optionLabels[o] ?? o),
            ),
        ],
        onChanged: _onChanged,
      ),
    );
  }
}

class _FirstDaySetting extends StatefulWidget {
  const _FirstDaySetting({required this.service});
  final OrgSettingsService service;

  @override
  State<_FirstDaySetting> createState() => _FirstDaySettingState();
}

class _FirstDaySettingState extends State<_FirstDaySetting> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.service.getNumber('locale.first_day_of_week', 1).toInt();
    if (_value < 0 || _value > 6) _value = 1;
  }

  Future<void> _change(int? value) async {
    if (value == null || value == _value) return;
    final previous = _value;
    setState(() => _value = value);
    try {
      await widget.service.set('locale.first_day_of_week', value);
      if (mounted) AppSnack.success(context, 'Impostazione salvata.');
    } catch (e) {
      if (mounted) {
        setState(() => _value = previous);
        AppSnack.error(context, 'Errore: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: DropdownButtonFormField<int>(
      initialValue: _value,
      decoration: const InputDecoration(labelText: 'Primo giorno settimana'),
      items: const [
        DropdownMenuItem(value: 1, child: Text('Lunedì')),
        DropdownMenuItem(value: 0, child: Text('Domenica')),
        DropdownMenuItem(value: 6, child: Text('Sabato')),
      ],
      onChanged: _change,
    ),
  );
}

/// Sezione Billing SaaS: entitlements + apertura Stripe su browser esterno.
class _BillingSaasSection extends ConsumerStatefulWidget {
  const _BillingSaasSection();

  @override
  ConsumerState<_BillingSaasSection> createState() =>
      _BillingSaasSectionState();
}

class _BillingSaasSectionState extends ConsumerState<_BillingSaasSection>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(entitlementsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entAsync = ref.watch(entitlementsProvider);
    final billing = ref.read(billingSaasServiceProvider);

    Future<void> checkout(String code) async {
      final err = await billing.openCheckout(code);
      if (err != null && context.mounted) AppSnack.error(context, err);
    }

    Future<void> portal() async {
      final err = await billing.openPortal();
      if (err != null && context.mounted) AppSnack.error(context, err);
    }

    return entAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.md),
        child: AppLoading(),
      ),
      error: (_, _) => AppErrorRetry(
        message: 'Stato abbonamento non disponibile.',
        onRetry: () => ref.invalidate(entitlementsProvider),
      ),
      data: (ent) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ent != null) _statusBanner(ent),
            const SizedBox(height: AppSpacing.md),
            for (final plan in SaasPlan.all)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: _planCard(context, plan, ent, () => checkout(plan.code)),
              ),
            if (ent != null && ent.status != 'trialing') ...[
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: portal,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Gestisci abbonamento'),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Il pagamento si apre nel browser (Stripe). L\'abbonamento è alla '
              'piattaforma PalestrIA.',
              style: TextStyle(fontSize: 12, color: AppColors.subtle),
            ),
          ],
        );
      },
    );
  }

  Widget _statusBanner(Entitlements ent) {
    final (bg, fg, text) = switch (ent.status) {
      'trialing' => (
        AppColors.purpleGlow,
        AppColors.primaryDark,
        ent.trialEnd == null
            ? 'Periodo di prova attivo'
            : 'Prova fino al ${_fmt(ent.trialEnd!)}',
      ),
      'active' => (
        const Color(0x1F06D6A0),
        AppColors.successEmeraldDark,
        'Abbonamento attivo (${ent.plan})',
      ),
      'past_due' => (
        const Color(0x1FF59E0B),
        const Color(0xFFB45309),
        'Pagamento in sospeso',
      ),
      'canceled' => (
        AppColors.dangerSurface,
        AppColors.dangerDark,
        'Abbonamento annullato',
      ),
      'unpaid' => (
        AppColors.dangerSurface,
        AppColors.dangerDark,
        'Pagamento non riuscito',
      ),
      'incomplete' => (
        AppColors.warnSurface,
        AppColors.warning,
        'Configurazione di pagamento incompleta',
      ),
      _ => (
        AppColors.cancelledBg,
        AppColors.cancelledText,
        'Abbonamento: ${ent.status}',
      ),
    };
    final planName = SaasPlan.all
        .firstWhere(
          (p) => p.code == ent.plan,
          orElse: () => SaasPlan(ent.plan, ent.plan, '', ''),
        )
        .name;
    final maxLabel = ent.maxClients == null ? '∞' : '${ent.maxClients}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: TextStyle(fontWeight: FontWeight.w700, color: fg),
          ),
          const SizedBox(height: 2),
          Text(
            'Piano $planName · ${ent.clientsCount}/$maxLabel clienti',
            style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
          ),
        ],
      ),
    );
  }

  Widget _planCard(
    BuildContext context,
    SaasPlan plan,
    Entitlements? ent,
    VoidCallback onSelect,
  ) {
    final isCurrent = ent?.plan == plan.code && ent?.status == 'active';
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: isCurrent ? primary : AppColors.border,
          width: isCurrent ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${plan.price} · ${plan.maxClientsLabel}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          if (isCurrent)
            const Chip(label: Text('Attuale'))
          else
            FilledButton(onPressed: onSelect, child: const Text('Scegli')),
        ],
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
