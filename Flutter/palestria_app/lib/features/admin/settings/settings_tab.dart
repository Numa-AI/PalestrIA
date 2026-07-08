import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/billing_saas.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import 'settings_company.dart';
import 'settings_payments.dart';
import 'settings_prefs.dart';
import 'settings_security.dart';
import 'settings_staff.dart';

/// Tab Impostazioni org (spec-admin §12). Versione con le sezioni principali:
/// Branding, Localizzazione, Pagamenti cliente, e Billing SaaS (Stripe web).
class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(orgSettingsProvider);

    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Errore: $e')),
      data: (service) {
        if (service == null) {
          return const Center(child: Text('Impostazioni non disponibili.'));
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.md, AppSpacing.md, AppSpacing.md, 100),
          children: [
            _section('🎨 Branding', [
              _BrandingSection(service: service),
            ]),
            _section('🌍 Localizzazione', [
              _TextSetting(
                service: service,
                settingKey: 'locale.timezone',
                label: 'Fuso orario',
                defaultValue: 'Europe/Rome',
              ),
              _TextSetting(
                service: service,
                settingKey: 'locale.currency',
                label: 'Valuta',
                defaultValue: 'EUR',
              ),
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
            _section('🔔 Notifiche', [
              NotifSection(service: service),
            ]),
            _section('📜 GDPR & Privacy', [
              GdprSection(service: service),
            ]),
            _section('🧩 Funzionalità', [
              FeaturesSection(service: service),
            ]),
            _section('👥 Staff / Membri', [
              StaffSection(service: service),
            ]),
            _section('⚠️ Sicurezza / Manutenzione', [
              SecuritySection(service: service),
            ]),
            _section('⭐ Abbonamento PalestrIA', [
              const _BillingSaasSection(),
            ]),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.lg),
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: AppShadows.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy)),
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
  late final TextEditingController _primaryColor;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _studioName = TextEditingController(
        text: widget.service.getString('branding.studio_name', ''));
    _primaryColor = TextEditingController(
        text: widget.service.getString('branding.primary_color', '#8B5CF6'));
  }

  @override
  void dispose() {
    _studioName.dispose();
    _primaryColor.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.service
          .set('branding.studio_name', _studioName.text.trim());
      await widget.service
          .set('branding.primary_color', _primaryColor.text.trim());
      final parsed = OrgBranding.parseHex(_primaryColor.text.trim());
      if (parsed != null) {
        await ref
            .read(orgBrandingProvider.notifier)
            .apply(widget.service.currentBranding());
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Branding salvato.')));
      }
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

class _TextSetting extends ConsumerStatefulWidget {
  const _TextSetting({
    required this.service,
    required this.settingKey,
    required this.label,
    required this.defaultValue,
  });

  final OrgSettingsService service;
  final String settingKey;
  final String label;
  final String defaultValue;

  @override
  ConsumerState<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends ConsumerState<_TextSetting> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: widget.service.getString(widget.settingKey, widget.defaultValue));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: widget.label,
          suffixIcon: IconButton(
            icon: const Icon(Icons.check, size: 18),
            onPressed: () async {
              await widget.service
                  .set(widget.settingKey, _controller.text.trim());
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Impostazione salvata.')));
              }
            },
          ),
        ),
      ),
    );
  }
}

/// Sezione Billing SaaS: entitlements + apertura Stripe su browser esterno.
class _BillingSaasSection extends ConsumerWidget {
  const _BillingSaasSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entAsync = ref.watch(entitlementsProvider);
    final billing = ref.read(billingSaasServiceProvider);

    Future<void> checkout(String code) async {
      final err = await billing.openCheckout(code);
      if (err != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }

    Future<void> portal() async {
      final err = await billing.openPortal();
      if (err != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    }

    return entAsync.when(
      loading: () => const Center(
          child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: CircularProgressIndicator())),
      error: (_, _) =>
          const Text('Stato abbonamento non disponibile.', style: AppText.meta),
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
          const Color(0x1F8B5CF6),
          AppColors.primaryDark,
          ent.trialEnd == null
              ? 'Periodo di prova attivo'
              : 'Prova fino al ${_fmt(ent.trialEnd!)}'
        ),
      'active' => (
          const Color(0x1F06D6A0),
          const Color(0xFF059669),
          'Abbonamento attivo (${ent.plan})'
        ),
      'past_due' => (
          const Color(0x1FF59E0B),
          const Color(0xFFB45309),
          'Pagamento in sospeso'
        ),
      _ => (
          const Color(0xFFF3F4F6),
          const Color(0xFF6B7280),
          'Abbonamento: ${ent.status}'
        ),
    };
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
          const SizedBox(height: 2),
          Text('${ent.clientsCount} clienti registrati',
              style: const TextStyle(fontSize: 12.5, color: AppColors.muted)),
        ],
      ),
    );
  }

  Widget _planCard(BuildContext context, SaasPlan plan, Entitlements? ent,
      VoidCallback onSelect) {
    final isCurrent = ent?.plan == plan.code && ent?.status == 'active';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
            color: isCurrent ? AppColors.primary : AppColors.border,
            width: isCurrent ? 2 : 1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                Text('${plan.price} · ${plan.maxClientsLabel}',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.muted)),
              ],
            ),
          ),
          if (isCurrent)
            const Chip(label: Text('Attuale'))
          else
            FilledButton(
              onPressed: onSelect,
              child: const Text('Scegli'),
            ),
        ],
      ),
    );
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
