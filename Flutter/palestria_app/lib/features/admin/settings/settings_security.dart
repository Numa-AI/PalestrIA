import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';

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
      text: widget.service.getString('maintenance.message', ''),
    );
  }

  @override
  void dispose() {
    _maintMsg.dispose();
    super.dispose();
  }

  Future<void> _setMaintMode(bool v) async {
    setState(() => _maintMode = v);
    try {
      await widget.service.set('maintenance.mode', v);
      if (mounted) {
        AppSnack.success(
          context,
          v ? 'Manutenzione attivata.' : 'Manutenzione disattivata.',
        );
      }
    } catch (e) {
      setState(() => _maintMode = !v);
      if (mounted) AppSnack.error(context, 'Errore: $e');
    }
  }

  Future<void> _saveMsg() async {
    setState(() => _savingMsg = true);
    try {
      await widget.service.set('maintenance.message', _maintMsg.text.trim());
      if (mounted) AppSnack.success(context, 'Messaggio salvato.');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore: $e');
    } finally {
      if (mounted) setState(() => _savingMsg = false);
    }
  }

  Future<void> _clearAllData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancella tutti i dati'),
        content: const Text(
          'Verranno eliminati: prenotazioni, schede, pagamenti, override '
          'calendario, notifiche e report. Account, membri e abbonamento NON '
          'saranno toccati.\n\nL\'operazione è IRREVERSIBILE.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.dangerDark,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continua'),
          ),
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
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.dangerDark,
            ),
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim() == 'ELIMINA'),
            child: const Text('Cancella'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (confirmed != true) {
      if (mounted) AppSnack.info(context, 'Operazione annullata.');
      return;
    }
    try {
      final res = await ref.read(supabaseProvider).rpc('admin_clear_all_data');
      if (res is Map && res['success'] == false) {
        throw Exception(res['error'] ?? 'Errore');
      }
      if (mounted) AppSnack.success(context, 'Dati organizzazione cancellati.');
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Errore cancellazione: $e');
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
          title: const Text(
            'Modalità manutenzione',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Quando attiva, i clienti vedono "sistema non disponibile". '
            'L\'admin continua ad accedere.',
            style: AppText.meta,
          ),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _maintMsg,
                decoration: const InputDecoration(
                  labelText: 'Messaggio manutenzione (opzionale)',
                ),
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
            color: AppColors.slate50,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: const Text(
            '💾 Backup/ripristino completo, verifica integrità dati e report '
            'XLSX restano sul pannello web. Il report fiscale PDF è nella tab '
            'Statistiche → "Scarica report fiscale".',
            style: AppText.meta,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.dangerSurface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: AppColors.dangerDark.withValues(alpha: 0.2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '🗑️ Cancella tutti i dati',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppColors.dangerDark,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Elimina prenotazioni, schede, pagamenti e configurazioni '
                'della org. Account e abbonamento restano. Irreversibile.',
                style: AppText.meta,
              ),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton(
                onPressed: _clearAllData,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.dangerDark,
                  side: const BorderSide(color: AppColors.dangerDark),
                ),
                child: const Text('Cancella dati org'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
