import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Sezione "Dati azienda & fiscali" (port di _settRenderCompany, admin-settings.js
/// §3): ragione sociale, P.IVA, CF, PEC, SDI, prefisso fattura, indirizzo
/// (oggetto `company.address`) e link Google Maps. Tutto su `org_settings`.
class CompanySection extends ConsumerStatefulWidget {
  const CompanySection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<CompanySection> createState() => _CompanySectionState();
}

class _CompanySectionState extends ConsumerState<CompanySection> {
  late final Map<String, TextEditingController> _c;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    final addr =
        (s.get('company.address') as Map?)?.cast<String, dynamic>() ?? {};
    String a(String k) => (addr[k] as String?) ?? '';
    _c = {
      'legal': TextEditingController(
        text: s.getString('company.legal_name', ''),
      ),
      'vat': TextEditingController(text: s.getString('company.vat_number', '')),
      'tax': TextEditingController(text: s.getString('company.tax_code', '')),
      'pec': TextEditingController(text: s.getString('company.pec', '')),
      'sdi': TextEditingController(text: s.getString('company.sdi_code', '')),
      'prefix': TextEditingController(
        text: s.getString('company.invoice_prefix', ''),
      ),
      'via': TextEditingController(text: a('via')),
      'cap': TextEditingController(text: a('cap')),
      'citta': TextEditingController(text: a('citta')),
      'provincia': TextEditingController(text: a('provincia')),
      'paese': TextEditingController(
        text: a('paese').isEmpty ? 'Italia' : a('paese'),
      ),
      'maps': TextEditingController(text: s.getString('company.maps_url', '')),
    };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final s = widget.service;
      await s.set('company.legal_name', _c['legal']!.text.trim());
      await s.set('company.vat_number', _c['vat']!.text.trim());
      await s.set('company.tax_code', _c['tax']!.text.trim());
      await s.set('company.pec', _c['pec']!.text.trim());
      await s.set('company.sdi_code', _c['sdi']!.text.trim().toUpperCase());
      await s.set('company.invoice_prefix', _c['prefix']!.text.trim());
      await s.set('company.address', {
        'via': _c['via']!.text.trim(),
        'cap': _c['cap']!.text.trim(),
        'citta': _c['citta']!.text.trim(),
        'provincia': _c['provincia']!.text.trim().toUpperCase(),
        'paese': _c['paese']!.text.trim(),
      });
      await s.set('company.maps_url', _c['maps']!.text.trim());
      if (mounted) AppSnack.success(context, 'Dati azienda salvati.');
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
        const Text(
          'Ragione sociale, partita IVA e dati per la fatturazione.',
          style: TextStyle(fontSize: 12.5, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpacing.md),
        _field('legal', 'Ragione sociale'),
        _field('vat', 'Partita IVA'),
        _field('tax', 'Codice fiscale'),
        _field('pec', 'PEC', keyboard: TextInputType.emailAddress),
        _field('sdi', 'Codice SDI', maxLen: 7),
        _field('prefix', 'Prefisso fattura', hint: 'Es. 2026/'),
        const Padding(
          padding: EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            'Indirizzo',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.subtle,
            ),
          ),
        ),
        _field('via', 'Via'),
        Row(
          children: [
            Expanded(child: _field('cap', 'CAP', maxLen: 5)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(flex: 2, child: _field('citta', 'Città')),
          ],
        ),
        Row(
          children: [
            Expanded(child: _field('provincia', 'Provincia', maxLen: 2)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(flex: 2, child: _field('paese', 'Paese')),
          ],
        ),
        _field(
          'maps',
          'Link Google Maps (mostrato nella home)',
          hint: 'https://maps.app.goo.gl/...',
          keyboard: TextInputType.url,
        ),
        const SizedBox(height: AppSpacing.md),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva dati azienda'),
        ),
      ],
    );
  }

  Widget _field(
    String key,
    String label, {
    String? hint,
    int? maxLen,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: TextField(
        controller: _c[key],
        keyboardType: keyboard,
        maxLength: maxLen,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          counterText: '',
        ),
      ),
    );
  }
}
