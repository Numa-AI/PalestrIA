import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';

/// Sezione "Sicurezza / Manutenzione" (port di _settRenderSecurity §11, adminOnly):
/// modalità manutenzione (`maintenance.mode`/`maintenance.message`) e cancellazione
/// di tutti i dati operativi della org (`admin_clear_all_data`, doppia conferma).
/// Backup/ripristino completo, verifica integrità e report XLSX restano sul web
/// (richiedono infra file-share non presente nell'app; il report fiscale è nella
/// tab Statistiche → "Scarica report fiscale").
class SecuritySection extends ConsumerStatefulWidget {
  const SecuritySection({super.key, required this.service});
  final OrgSettingsService service;

  @override
  ConsumerState<SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends ConsumerState<SecuritySection> {
  late bool _maintMode;
  late final TextEditingController _maintMsg;
  bool _savingMsg = false;

  @override
  void initState() {
    super.initState();
    _maintMode = widget.service.getBool('maintenance.mode', false);
    _maintMsg = TextEditingController(
        text: widget.service.getString('maintenance.message', ''));
  }

  @override
  void dispose() {
    _maintMsg.dispose();
    super.dispose();
  }

  Future<void> _setMaintMode(bool v) async {
    setState(() => _maintMode = v);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.service.set('maintenance.mode', v);
      messenger.showSnackBar(SnackBar(
          content: Text(
              v ? 'Manutenzione attivata.' : 'Manutenzione disattivata.')));
    } catch (e) {
      setState(() => _maintMode = !v);
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    }
  }

  Future<void> _saveMsg() async {
    setState(() => _savingMsg = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.service.set('maintenance.message', _maintMsg.text.trim());
      messenger.showSnackBar(const SnackBar(content: Text('Messaggio salvato.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Errore: $e')));
    } finally {
      if (mounted) setState(() => _savingMsg = false);
    }
  }

  Future<void> _clearAllData() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancella tutti i dati'),
        content: const Text(
            'Verranno eliminati: prenotazioni, schede, pagamenti, override '
            'calendario, notifiche e report. Account, membri e abbonamento NON '
            'saranno toccati.\n\nL\'operazione è IRREVERSIBILE.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continua')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Conferma cancellazione'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Per confermare, scrivi ELIMINA in maiuscolo:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'ELIMINA'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annulla')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626)),
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim() == 'ELIMINA'),
              child: const Text('Cancella')),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Operazione annullata.')));
      return;
    }
    try {
      final res =
          await ref.read(supabaseProvider).rpc('admin_clear_all_data');
      if (res is Map && res['success'] == false) {
        throw Exception(res['error'] ?? 'Errore');
      }
      messenger.showSnackBar(
          const SnackBar(content: Text('Dati organizzazione cancellati.')));
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Errore cancellazione: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _maintMode,
          onChanged: _setMaintMode,
          title: const Text('Modalità manutenzione',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          subtitle: const Text(
              'Quando attiva, i clienti vedono "sistema non disponibile". '
              'L\'admin continua ad accedere.',
              style: AppText.meta),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _maintMsg,
                decoration: const InputDecoration(
                    labelText: 'Messaggio manutenzione (opzionale)'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              onPressed: _savingMsg ? null : _saveMsg,
              child: Text(_savingMsg ? '...' : 'Salva'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: const Text(
              '💾 Backup/ripristino completo, verifica integrità dati e report '
              'XLSX restano sul pannello web. Il report fiscale PDF è nella tab '
              'Statistiche → "Scarica report fiscale".',
              style: AppText.meta),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x33DC2626)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('🗑️ Cancella tutti i dati',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFDC2626))),
              const SizedBox(height: 4),
              const Text(
                  'Elimina prenotazioni, schede, pagamenti e configurazioni '
                  'della org. Account e abbonamento restano. Irreversibile.',
                  style: AppText.meta),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                onPressed: _clearAllData,
                style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFDC2626))),
                child: const Text('Cancella dati org'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
