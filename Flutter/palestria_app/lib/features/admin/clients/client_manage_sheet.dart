import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/theme/tokens.dart';

Future<bool?> showClientManageSheet(
  BuildContext context,
  WidgetRef ref,
  AdminProfile profile,
) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => _ClientManageSheet(profile: profile),
);

class _ClientManageSheet extends ConsumerStatefulWidget {
  const _ClientManageSheet({required this.profile});
  final AdminProfile profile;

  @override
  ConsumerState<_ClientManageSheet> createState() => _ClientManageSheetState();
}

class _ClientManageSheetState extends ConsumerState<_ClientManageSheet> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _cf;
  late final TextEditingController _address;
  late final TextEditingController _city;
  late final TextEditingController _cap;
  DateTime? _cert;
  DateTime? _insurance;
  late bool _signed;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name = TextEditingController(text: p.name);
    _email = TextEditingController(text: p.email);
    _phone = TextEditingController(text: p.whatsapp);
    _cf = TextEditingController(text: p.codiceFiscale);
    _address = TextEditingController(text: p.indirizzoVia);
    _city = TextEditingController(text: p.indirizzoPaese);
    _cap = TextEditingController(text: p.indirizzoCap);
    _cert = p.medicalCertExpiry;
    _insurance = p.insuranceExpiry;
    _signed = p.documentoFirmato;
  }

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _cf, _address, _city, _cap]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .94,
    ),
    decoration: const BoxDecoration(
      color: Color(0xFFF8F7FC),
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    child: Column(
      children: [
        _header(),
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
                _sectionTitle('Contatti', Icons.contact_phone_outlined),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _name,
                        'Nome e cognome',
                        Icons.person_outline,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _field(
                        _phone,
                        'WhatsApp',
                        Icons.phone_outlined,
                        keyboard: TextInputType.phone,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _field(
                  _email,
                  'Email di accesso',
                  Icons.alternate_email,
                  keyboard: TextInputType.emailAddress,
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 5),
                  child: Text(
                    'Il cambio email aggiorna anche l’identità di login del cliente.',
                    style: TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _sectionTitle('Anagrafica', Icons.badge_outlined),
                _field(_cf, 'Codice fiscale', Icons.fingerprint),
                const SizedBox(height: 10),
                _field(_address, 'Indirizzo', Icons.home_outlined),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _field(
                        _city,
                        'Comune',
                        Icons.location_city_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _field(
                        _cap,
                        'CAP',
                        Icons.pin_drop_outlined,
                        keyboard: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _sectionTitle(
                  'Idoneità e documenti',
                  Icons.health_and_safety_outlined,
                ),
                Row(
                  children: [
                    Expanded(
                      child: _dateCard(
                        'Certificato medico',
                        _cert,
                        () => _pick(true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _dateCard(
                        'Assicurazione',
                        _insurance,
                        () => _pick(false),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SwitchListTile.adaptive(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  tileColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: Color(0xFFE7E2F2)),
                  ),
                  value: _signed,
                  onChanged: (v) => setState(() => _signed = v),
                  title: const Text(
                    'Documento firmato',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Flag amministrativo non modificabile dal cliente.',
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Salvataggio…' : 'Salva cliente'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(22, 14, 14, 20),
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFF312E81), Color(0xFF7C3AED)]),
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
                color: Colors.white.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.manage_accounts_outlined,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Gestisci cliente',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    widget.profile.name,
                    style: const TextStyle(color: Colors.white70),
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

  Widget _sectionTitle(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Row(
      children: [
        Icon(icon, size: 19, color: AppColors.primary),
        const SizedBox(width: 7),
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label,
    IconData icon, {
    TextInputType? keyboard,
  }) => TextField(
    controller: controller,
    keyboardType: keyboard,
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE7E2F2)),
      ),
    ),
  );

  Widget _dateCard(String title, DateTime? date, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7E2F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 11, color: AppColors.muted),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              const Icon(
                Icons.event_outlined,
                size: 18,
                color: AppColors.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  date == null ? 'Non impostata' : _displayDate(date),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _pick(bool cert) async {
    final current = cert ? _cert : _insurance;
    final value = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 10),
    );
    if (value != null) {
      setState(() => cert ? _cert = value : _insurance = value);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return _error('Nome obbligatorio.');
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      return _error('Email non valida.');
    }
    setState(() => _saving = true);
    try {
      final response = await ref
          .read(supabaseProvider)
          .functions
          .invoke(
            'admin-manage-client',
            body: {
              'user_id': widget.profile.id,
              'name': _name.text.trim(),
              'email': _email.text.trim().toLowerCase(),
              'whatsapp': _phone.text.trim(),
              'medical_cert_expiry': _cert == null ? null : _ymd(_cert!),
              'insurance_expiry': _insurance == null ? null : _ymd(_insurance!),
              'codice_fiscale': _cf.text.trim().toUpperCase(),
              'indirizzo_via': _address.text.trim(),
              'indirizzo_paese': _city.text.trim(),
              'indirizzo_cap': _cap.text.trim(),
              'documento_firmato': _signed,
            },
          );
      final data = (response.data as Map? ?? const {}).cast<String, dynamic>();
      if (data['ok'] != true) {
        throw Exception(data['details'] ?? data['error'] ?? 'update_failed');
      }
      ref.invalidate(adminProfilesProvider);
      ref.invalidate(adminBookingsProvider);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      _error('Salvataggio non riuscito: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _error(String text) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), backgroundColor: AppColors.dangerDark),
  );
  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String _displayDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
