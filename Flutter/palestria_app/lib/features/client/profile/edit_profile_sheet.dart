import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/normalize.dart';
import '../../../core/models/user_profile.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

/// Modal "Modifica profilo" (§7.7 spec-client), come bottom sheet.
Future<void> showEditProfileSheet(
    BuildContext context, WidgetRef ref, UserProfile profile) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EditProfileSheet(profile: profile),
  );
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final TextEditingController _email;
  late final TextEditingController _whatsapp;
  late final TextEditingController _cf;
  late final TextEditingController _via;
  late final TextEditingController _paese;
  late final TextEditingController _cap;
  late final TextEditingController _password;
  late final TextEditingController _password2;
  late final TextEditingController _certExpiryCtrl;
  late final TextEditingController _insuranceExpiryCtrl;
  DateTime? _certExpiry;
  late bool _privacy;
  String? _error;
  bool _saving = false;

  UserProfile get p => widget.profile;

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: p.email);
    _whatsapp = TextEditingController(text: p.whatsapp ?? '');
    _cf = TextEditingController(text: p.codiceFiscale ?? '');
    _via = TextEditingController(text: p.indirizzoVia ?? '');
    _paese = TextEditingController(text: p.indirizzoPaese ?? '');
    _cap = TextEditingController(text: p.indirizzoCap ?? '');
    _password = TextEditingController();
    _password2 = TextEditingController();
    _certExpiry = p.medicalCertExpiry;
    _certExpiryCtrl = TextEditingController(text: _formatDate(_certExpiry));
    _insuranceExpiryCtrl =
        TextEditingController(text: _formatDate(p.insuranceExpiry));
    _privacy = p.privacyPrenotazioni;
  }

  @override
  void dispose() {
    for (final c in [
      _email, _whatsapp, _cf, _via, _paese, _cap, _password, _password2,
      _certExpiryCtrl, _insuranceExpiryCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  static String _formatDate(DateTime? value) => value == null
      ? ''
      : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

  Future<void> _save() async {
    setState(() => _error = null);
    final email = _email.text.trim().toLowerCase();
    if (email.isEmpty) {
      setState(() => _error = 'L\'email è obbligatoria.');
      return;
    }
    final cap = _cap.text.trim();
    if (cap.isNotEmpty && !RegExp(r'^\d{5}$').hasMatch(cap)) {
      setState(() => _error = 'Il CAP deve avere 5 cifre.');
      return;
    }
    if (_password.text.isNotEmpty) {
      if (_password.text.length < 6) {
        setState(
            () => _error = 'La password deve avere almeno 6 caratteri.');
        return;
      }
      if (_password.text != _password2.text) {
        setState(() => _error = 'Le password non coincidono.');
        return;
      }
    }

    setState(() => _saving = true);
    final client = ref.read(supabaseProvider);
    final session = ref.read(sessionProvider)!;
    final orgContext = await ref.read(orgContextProvider.future);

    try {
      final phone = _whatsapp.text.trim().isEmpty
          ? null
          : normalizePhone(_whatsapp.text);
      if (phone != null && phone != p.whatsapp) {
        final taken = await client.rpc('is_whatsapp_taken', params: {
          'phone': phone,
          'exclude_user_id': session.user.id,
        });
        if (taken == true) {
          setState(() {
            _error = 'Questo numero WhatsApp è già registrato.';
            _saving = false;
          });
          return;
        }
      }

      final emailChanged = email != p.email.toLowerCase();
      final updates = <String, dynamic>{
        'id': p.id,
        'org_id': orgContext.orgId,
        'name': p.name,
        // email su profiles solo se INVARIATA (il cambio passa da auth)
        'email': emailChanged ? p.email : email,
        'whatsapp': phone,
        'codice_fiscale':
            _cf.text.trim().isEmpty ? null : _cf.text.trim().toUpperCase(),
        'indirizzo_via': _via.text.trim().isEmpty ? null : _via.text.trim(),
        'indirizzo_paese':
            _paese.text.trim().isEmpty ? null : normalizeComune(_paese.text),
        'indirizzo_cap': cap.isEmpty ? null : cap,
        'privacy_prenotazioni': _privacy,
      };

      // Certificato: aggiorna scadenza + append alla history (come il web).
      final newCert = _certExpiry?.toIso8601String().substring(0, 10);
      final oldCert = p.medicalCertExpiry?.toIso8601String().substring(0, 10);
      if (newCert != oldCert) {
        updates['medical_cert_expiry'] = newCert;
        final history = await client
            .from('profiles')
            .select('medical_cert_history')
            .eq('id', p.id)
            .maybeSingle();
        final list =
            ((history?['medical_cert_history'] as List?) ?? []).toList();
        list.add({
          'scadenza': newCert,
          'aggiornatoIl': DateTime.now().toIso8601String(),
        });
        updates['medical_cert_history'] = list;
      }

      await client.from('profiles').upsert(updates).timeout(
          const Duration(seconds: 12));

      var emailPending = false;
      if (emailChanged) {
        await client.auth.updateUser(UserAttributes(email: email));
        emailPending = true;
      }
      if (_password.text.isNotEmpty) {
        await client.auth
            .updateUser(UserAttributes(password: _password.text));
      }

      ref.invalidate(userProfileProvider);
      if (!mounted) return;
      Navigator.pop(context);
      AppSnack.success(
        context,
        emailPending
            ? 'Profilo aggiornato. Controlla la tua email per confermare il cambio di indirizzo.'
            : 'Profilo aggiornato.',
      );
    } on AuthException catch (e) {
      setState(() {
        _error = 'Errore: ${e.message}';
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Errore di rete. Riprova.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Il campo scadenza certificato è editabile dal cliente solo se la org
    // non l'ha riservato al trainer (setting 'cert_scadenza_editable').
    final certEditable = ref
            .watch(orgSettingsProvider)
            .value
            ?.getBool('cert_scadenza_editable', true) ??
        true;
    // Niente sezione password per gli utenti OAuth (Google/Apple): non hanno
    // una password Supabase da cambiare.
    final provider = Supabase
        .instance.client.auth.currentSession?.user.appMetadata['provider']
        as String?;
    final showPasswordSection = provider == null || provider == 'email';

    Widget sectionTitle(String title) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: 6),
          child: Text(title.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.subtle,
                  letterSpacing: 0.6)),
        );

    return SafeArea(
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.sm, AppSpacing.xl, AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: Text(
                      p.name.isEmpty ? '?' : p.name[0].toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Modifica profilo',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        Text(p.email,
                            style: AppText.meta,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
              sectionTitle('Dati personali'),
              TextFormField(
                enabled: false,
                initialValue: p.name,
                decoration: const InputDecoration(labelText: 'Nome completo'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _whatsapp,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                    labelText: 'Numero WhatsApp',
                    hintText: '+39 348 1234567'),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _cf,
                textCapitalization: TextCapitalization.characters,
                maxLength: 16,
                decoration:
                    const InputDecoration(labelText: 'Codice Fiscale'),
              ),
              sectionTitle('Indirizzo'),
              TextField(
                controller: _via,
                decoration:
                    const InputDecoration(labelText: 'Via / Indirizzo'),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _paese,
                      decoration:
                          const InputDecoration(labelText: 'Paese / Città'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _cap,
                      keyboardType: TextInputType.number,
                      maxLength: 5,
                      decoration: const InputDecoration(labelText: 'CAP'),
                    ),
                  ),
                ],
              ),
              sectionTitle('Documenti'),
              _dateField(
                label: 'Scadenza certificato medico',
                controller: _certExpiryCtrl,
                current: _certExpiry,
                onChanged: certEditable
                    ? (d) => setState(() {
                          _certExpiry = d;
                          _certExpiryCtrl.text = _formatDate(d);
                        })
                    : null,
              ),
              const SizedBox(height: AppSpacing.md),
              _dateField(
                label: 'Scadenza assicurazione (gestita dal trainer)',
                controller: _insuranceExpiryCtrl,
                current: p.insuranceExpiry,
                onChanged: null, // sempre disabilitata
              ),
              if (showPasswordSection) ...[
                sectionTitle('Sicurezza'),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText:
                          'Nuova password (lascia vuoto per non cambiare)'),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _password2,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Conferma nuova password'),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              CheckboxListTile(
                value: _privacy,
                onChanged: (v) => setState(() => _privacy = v ?? true),
                title: const Text('Privacy prenotazioni',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                subtitle: const Text(
                    'Se attivo, il tuo nome non sarà visibile agli altri nelle prenotazioni.',
                    style: TextStyle(fontSize: 12.5)),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              if (_error != null)
                Container(
                  margin: const EdgeInsets.only(top: AppSpacing.sm),
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: AppColors.dangerSurface,
                    border: Border.all(color: const Color(0xFFFECACA)),
                    borderRadius: BorderRadius.circular(AppRadius.input),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(
                          color: AppColors.dangerDark,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600)),
                ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Salvataggio...' : 'Salva modifiche'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dateField({
    required String label,
    required TextEditingController controller,
    required DateTime? current,
    required ValueChanged<DateTime?>? onChanged,
  }) {
    return TextField(
      enabled: onChanged != null,
      readOnly: true,
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
      ),
      onTap: onChanged == null
          ? null
          : () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: current ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(picked);
            },
    );
  }
}
