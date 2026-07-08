import 'package:flutter/material.dart';

import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';

/// Sezione "Policy prenotazione & cancellazione" (port di _settRenderPolicy §5,
/// solo il form principale su `booking.policy.*`). Le toggle legacy
/// cert/assicurazione/badge (classi Storage separate nel web) sono rimandate.
class PolicySection extends StatefulWidget {
  const PolicySection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  State<PolicySection> createState() => _PolicySectionState();
}

class _PolicySectionState extends State<PolicySection> {
  late final TextEditingController _freeHours;
  late final TextEditingController _penalty;
  late final TextEditingController _maxAdvance;
  late bool _requiresAccount;
  late String _cancelMode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    _freeHours = TextEditingController(
        text: s.getNumber('booking.policy.free_cancel_hours', 24).toString());
    _penalty = TextEditingController(
        text: s.getNumber('booking.policy.penalty_pct', 50).toString());
    _maxAdvance = TextEditingController(
        text: s.getNumber('booking.policy.max_advance_days', 0).toString());
    _requiresAccount = s.getBool('booking.policy.requires_account', false);
    _cancelMode = s.getString('booking.policy.cancel_mode', 'penalty');
  }

  @override
  void dispose() {
    _freeHours.dispose();
    _penalty.dispose();
    _maxAdvance.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final s = widget.service;
      await s.set('booking.policy.free_cancel_hours',
          int.tryParse(_freeHours.text.trim()) ?? 0);
      await s.set('booking.policy.penalty_pct',
          int.tryParse(_penalty.text.trim()) ?? 0);
      await s.set('booking.policy.max_advance_days',
          int.tryParse(_maxAdvance.text.trim()) ?? 0);
      await s.set('booking.policy.requires_account', _requiresAccount);
      await s.set('booking.policy.cancel_mode', _cancelMode);
      messenger
          .showSnackBar(const SnackBar(content: Text('Policy salvata.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Regole su anticipo, cancellazione gratuita e penali.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
        const SizedBox(height: AppSpacing.md),
        _num(_freeHours, 'Ore di cancellazione gratuita'),
        _num(_penalty, 'Penale cancellazione tardiva (%)'),
        _num(_maxAdvance, 'Anticipo massimo prenotazione (giorni, 0 = illimitato)'),
        const SizedBox(height: AppSpacing.sm),
        DropdownButtonFormField<String>(
          initialValue: _cancelMode,
          decoration: const InputDecoration(labelText: 'Modalità cancellazione'),
          items: const [
            DropdownMenuItem(value: 'penalty', child: Text('Penale percentuale')),
            DropdownMenuItem(
                value: 'block', child: Text('Blocca cancellazione tardiva')),
            DropdownMenuItem(value: 'free', child: Text('Sempre gratuita')),
          ],
          onChanged: (v) => setState(() => _cancelMode = v ?? 'penalty'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _requiresAccount,
          onChanged: (v) => setState(() => _requiresAccount = v),
          title: const Text('Richiedi account per prenotare',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: const Text(
              'Solo i clienti registrati possono prenotare.',
              style: AppText.meta),
        ),
        const SizedBox(height: AppSpacing.sm),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva policy'),
        ),
      ],
    );
  }

  Widget _num(TextEditingController c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
        ),
      );
}

/// Sezione "Notifiche" (port di _settRenderNotif §6): conferme, promemoria,
/// avvisi admin (`notif.*`) e canali (`notif.channels`).
class NotifSection extends StatefulWidget {
  const NotifSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  State<NotifSection> createState() => _NotifSectionState();
}

class _NotifSectionState extends State<NotifSection> {
  late bool _confirmation;
  late bool _reminderEnabled;
  late final TextEditingController _reminderHours;
  late bool _adminNew;
  late bool _chPush;
  late bool _chEmail;
  late bool _chWhatsapp;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    _confirmation = s.getBool('notif.booking_confirmation', true);
    _reminderEnabled = s.getBool('notif.reminder_enabled', true);
    _reminderHours = TextEditingController(
        text: s.getNumber('notif.reminder_hours', 24).toString());
    _adminNew = s.getBool('notif.admin_new_booking', true);
    final ch =
        (s.get('notif.channels') as Map?)?.cast<String, dynamic>() ?? {};
    _chPush = (ch['push'] as bool?) ?? true;
    _chEmail = (ch['email'] as bool?) ?? false;
    _chWhatsapp = (ch['whatsapp'] as bool?) ?? false;
  }

  @override
  void dispose() {
    _reminderHours.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final s = widget.service;
      await s.set('notif.booking_confirmation', _confirmation);
      await s.set('notif.reminder_enabled', _reminderEnabled);
      await s.set('notif.reminder_hours',
          int.tryParse(_reminderHours.text.trim()) ?? 24);
      await s.set('notif.admin_new_booking', _adminNew);
      await s.set('notif.channels', {
        'push': _chPush,
        'email': _chEmail,
        'whatsapp': _chWhatsapp,
      });
      messenger
          .showSnackBar(const SnackBar(content: Text('Notifiche salvate.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toggle('Conferma prenotazione al cliente', _confirmation,
            (v) => setState(() => _confirmation = v),
            sub: 'Notifica al cliente quando prenota.'),
        _toggle('Promemoria lezione', _reminderEnabled,
            (v) => setState(() => _reminderEnabled = v),
            sub: 'Invia un promemoria prima della lezione.'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: TextField(
            controller: _reminderHours,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Anticipo promemoria (ore)'),
          ),
        ),
        _toggle('Avvisa admin su nuova prenotazione', _adminNew,
            (v) => setState(() => _adminNew = v),
            sub: 'Push agli admin della org per ogni nuova prenotazione.'),
        const Divider(height: AppSpacing.lg),
        const Text('Canali di invio',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.subtle)),
        _toggle('📲 Push', _chPush, (v) => setState(() => _chPush = v)),
        _toggle('✉️ Email', _chEmail, (v) => setState(() => _chEmail = v)),
        _toggle('💬 WhatsApp', _chWhatsapp,
            (v) => setState(() => _chWhatsapp = v)),
        const SizedBox(height: AppSpacing.sm),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva notifiche'),
        ),
      ],
    );
  }

  Widget _toggle(String title, bool value, ValueChanged<bool> onChanged,
          {String? sub}) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: sub == null ? null : Text(sub, style: AppText.meta),
      );
}

/// Sezione "GDPR & Privacy" (port di _settRenderGdpr §8): link privacy/termini
/// + giorni di conservazione dati (`gdpr.*`).
class GdprSection extends StatefulWidget {
  const GdprSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  State<GdprSection> createState() => _GdprSectionState();
}

class _GdprSectionState extends State<GdprSection> {
  late final TextEditingController _privacy;
  late final TextEditingController _terms;
  late final TextEditingController _retention;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = widget.service;
    _privacy =
        TextEditingController(text: s.getString('gdpr.privacy_url', ''));
    _terms = TextEditingController(text: s.getString('gdpr.terms_url', ''));
    _retention = TextEditingController(
        text: s.getNumber('gdpr.data_retention_days', 0).toString());
  }

  @override
  void dispose() {
    _privacy.dispose();
    _terms.dispose();
    _retention.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final s = widget.service;
      await s.set('gdpr.privacy_url', _privacy.text.trim());
      await s.set('gdpr.terms_url', _terms.text.trim());
      await s.set('gdpr.data_retention_days',
          int.tryParse(_retention.text.trim()) ?? 0);
      messenger.showSnackBar(const SnackBar(content: Text('GDPR salvato.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Link ai documenti legali e conservazione dei dati.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
        const SizedBox(height: AppSpacing.md),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: TextField(
            controller: _privacy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
                labelText: 'URL informativa privacy',
                hintText: 'https://…/privacy'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: TextField(
            controller: _terms,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
                labelText: 'URL termini e condizioni',
                hintText: 'https://…/termini'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: TextField(
            controller: _retention,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Conservazione dati (giorni, 0 = illimitato)'),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Salvataggio...' : 'Salva GDPR'),
        ),
      ],
    );
  }
}

/// Sezione "Funzionalità" (port di _settRenderFeatures §9): toggle per modulo
/// (`features.<key>`), salvati singolarmente al cambio.
class FeaturesSection extends StatefulWidget {
  const FeaturesSection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  State<FeaturesSection> createState() => _FeaturesSectionState();
}

class _FeaturesSectionState extends State<FeaturesSection> {
  static const _features = [
    ('workout_plans', '💪 Schede di allenamento', 'Modulo schede, esercizi e progressi.'),
    ('client_manage_plans', '✏️ Schede modificabili dai clienti',
        'I clienti possono creare e modificare le proprie schede (oltre a registrare i log). Richiede la policy DB abilitata.'),
    ('nutrition', '🥗 Nutrizione', 'Piani alimentari per i clienti.'),
    ('messaging', '💬 Messaggistica', 'Notifiche push broadcast ai clienti.'),
    ('ai_reports', '🤖 Report AI', 'Report mensili generati con AI.'),
    ('client_online_payments', '💳 Pagamenti online',
        'I clienti pagano le lezioni online con Stripe.'),
  ];

  Future<void> _set(String key, bool val) async {
    setState(() {});
    try {
      await widget.service.set('features.$key', val);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Errore: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
            'Attiva/disattiva i moduli per la tua organizzazione. La '
            'disponibilità per piano è gestita a parte.',
            style: TextStyle(fontSize: 12.5, color: AppColors.muted)),
        const SizedBox(height: AppSpacing.sm),
        for (final f in _features)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: widget.service.getBool('features.${f.$1}', false),
            onChanged: (v) => _set(f.$1, v),
            title: Text(f.$2,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(f.$3, style: AppText.meta),
          ),
      ],
    );
  }
}
