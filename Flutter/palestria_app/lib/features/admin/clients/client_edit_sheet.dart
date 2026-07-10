import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/theme/tokens.dart';

/// Editor documenti cliente lato admin (port dei modali openCertModal/
/// openAssicModal, admin-analytics.js): scadenza certificato medico,
/// assicurazione e stato documento firmato. Salva su `profiles` per id.
Future<void> showClientDocsEditSheet(
  BuildContext context,
  WidgetRef ref,
  AdminProfile profile,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _ClientDocsEditSheet(profile: profile),
  );
}

class _ClientDocsEditSheet extends ConsumerStatefulWidget {
  const _ClientDocsEditSheet({required this.profile});
  final AdminProfile profile;

  @override
  ConsumerState<_ClientDocsEditSheet> createState() =>
      _ClientDocsEditSheetState();
}

class _ClientDocsEditSheetState extends ConsumerState<_ClientDocsEditSheet> {
  DateTime? _cert;
  DateTime? _ins;
  late bool _docSigned;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cert = widget.profile.medicalCertExpiry;
    _ins = widget.profile.insuranceExpiry;
    _docSigned = widget.profile.documentoFirmato;
  }

  static String? _ymd(DateTime? d) => d == null
      ? null
      : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick(bool cert) async {
    final now = DateTime.now();
    final initial = (cert ? _cert : _ins) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 10),
    );
    if (picked != null) {
      setState(() => cert ? _cert = picked : _ins = picked);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(supabaseProvider)
          .from('profiles')
          .update({
            'medical_cert_expiry': _ymd(_cert),
            'insurance_expiry': _ymd(_ins),
            'documento_firmato': _docSigned,
          })
          .eq('id', widget.profile.id);
      ref.invalidate(adminProfilesProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Documenti aggiornati.')),
      );
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Documenti · ${widget.profile.name}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.md),
            _dateRow(
              '🏥 Scadenza certificato medico',
              _cert,
              () => _pick(true),
              () => setState(() => _cert = null),
            ),
            const SizedBox(height: AppSpacing.sm),
            _dateRow(
              '📋 Scadenza assicurazione',
              _ins,
              () => _pick(false),
              () => setState(() => _ins = null),
            ),
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _docSigned,
              onChanged: (v) => setState(() => _docSigned = v),
              title: const Text(
                'Documento firmato',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Annulla'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Salvataggio...' : 'Salva'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateRow(
    String label,
    DateTime? value,
    VoidCallback onPick,
    VoidCallback onClear,
  ) {
    final text = value == null
        ? 'Non impostata'
        : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
              ),
              Text(
                text,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: 'Rimuovi',
            onPressed: onClear,
          ),
        OutlinedButton.icon(
          onPressed: onPick,
          icon: const Icon(Icons.event, size: 18),
          label: const Text('Scegli'),
        ),
      ],
    );
  }
}
