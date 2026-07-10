import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/admin_repository.dart';
import '../../../core/data/client_operations.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../payments/client_sale_sheet.dart';

class ClientFinancialPanel extends ConsumerWidget {
  const ClientFinancialPanel({super.key, required this.client});
  final AdminClient client;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = client.userId;
    if (userId == null) {
      return const AppCard(
        margin: EdgeInsets.only(top: AppSpacing.md),
        child: Row(
          children: [
            Icon(Icons.person_add_alt_1_outlined, color: AppColors.amber),
            SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                'Profilo non registrato: pacchetti e abbonamenti richiedono un account cliente verificato.',
              ),
            ),
          ],
        ),
      );
    }
    final summary = ref.watch(clientFinancialSummaryProvider(userId));
    return summary.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, _) => AppErrorRetry(
        message: 'Stato economico non disponibile.',
        onRetry: () => ref.invalidate(clientFinancialSummaryProvider(userId)),
      ),
      data: (data) => _content(context, ref, userId, data),
    );
  }

  Widget _content(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientFinancialSummary data,
  ) {
    final tone = data.health.hasBlockingIssue
        ? _HealthTone.danger
        : data.health.hasWarning
        ? _HealthTone.warning
        : _HealthTone.ok;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.md),
        _healthBanner(tone, data),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: _metric(
                'Incassato',
                '€${_money(data.collected)}',
                Icons.savings_outlined,
                AppColors.green600,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: data.model == 'pay_per_session'
                  ? _metric(
                      'Credito lezioni',
                      '€${_money(data.credit)}',
                      Icons.pending_actions_outlined,
                      data.unpaid > 0 ? AppColors.dangerDark : AppColors.subtle,
                    )
                  : _metric(
                      'Modello',
                      _billingLabel(data.model),
                      Icons.account_balance_wallet_outlined,
                      AppColors.primary,
                    ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _billingModelCard(context, ref, userId, data),
        if (data.activePackage case final package?) ...[
          const SizedBox(height: AppSpacing.md),
          _packageCard(context, ref, userId, package),
        ],
        if (data.activeMembership case final membership?) ...[
          const SizedBox(height: AppSpacing.md),
          _membershipCard(context, ref, userId, membership),
        ],
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _action(
              context,
              Icons.confirmation_number_outlined,
              'Vendi pacchetto',
              () => _sale(context, ref, ClientSaleKind.package),
            ),
            _action(
              context,
              Icons.calendar_month_outlined,
              'Nuovo abbonamento',
              () => _sale(context, ref, ClientSaleKind.membership),
            ),
            _action(
              context,
              Icons.tune,
              'Rettifica',
              () => _sale(context, ref, ClientSaleKind.adjustment),
            ),
            _action(
              context,
              data.health.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
              data.health.archived ? 'Riattiva' : 'Archivia',
              () => _archive(context, ref, userId, data.health.archived),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _reset(context, ref, userId),
            icon: const Icon(
              Icons.delete_sweep_outlined,
              color: AppColors.dangerDark,
            ),
            label: const Text(
              'Azzera dati operativi',
              style: TextStyle(color: AppColors.dangerDark),
            ),
          ),
        ),
      ],
    );
  }

  Widget _healthBanner(_HealthTone tone, ClientFinancialSummary data) {
    final (color, icon, title) = switch (tone) {
      _HealthTone.ok => (
        AppColors.green600,
        Icons.verified_outlined,
        'Cliente in regola',
      ),
      _HealthTone.warning => (
        AppColors.amber,
        Icons.warning_amber_rounded,
        'Documenti da verificare',
      ),
      _HealthTone.danger => (
        AppColors.dangerDark,
        Icons.report_gmailerrorred_outlined,
        data.health.archived
            ? 'Cliente archiviato'
            : data.health.unpaidOverThreshold
            ? 'Soglia debiti superata'
            : 'Copertura economica mancante',
      ),
    };
    final details = <String>[
      if (data.health.medicalCertExpired) 'certificato scaduto',
      if (data.health.insuranceExpired) 'assicurazione scaduta',
      if (data.health.unpaidOverThreshold) 'nuove prenotazioni bloccate',
      if (data.health.billingCoverageMissing)
        data.model == 'package'
            ? 'nessun pacchetto attivo'
            : 'nessun abbonamento attivo',
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: .25)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.w800, color: color),
                ),
                if (details.isNotEmpty)
                  Text(
                    details.join(' · '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, IconData icon, Color color) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.borderGray),
        ),
        child: Row(
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9.5,
                      letterSpacing: .6,
                      fontWeight: FontWeight.w700,
                      color: AppColors.subtle,
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: AppText.tabularNums,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _billingModelCard(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientFinancialSummary data,
  ) {
    const labels = {
      'pay_per_session': 'Pagamento a lezione',
      'package': 'Pacchetto / carnet',
      'monthly': 'Abbonamento',
      'free': 'Gratuito',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F3FF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.account_balance_wallet_outlined,
            color: AppColors.primary,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Modello tariffario',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            tooltip: 'Prezzo personalizzato e note',
            onPressed: () => _editBillingTerms(context, ref, userId, data),
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
          DropdownButton<String>(
            value: data.model,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(14),
            items: [
              for (final e in labels.entries)
                DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value, style: const TextStyle(fontSize: 12)),
                ),
            ],
            onChanged: (value) async {
              if (value == null || value == data.model) return;
              await ref
                  .read(clientOperationsRepositoryProvider)
                  .setBillingModel(
                    userId: userId,
                    model: value,
                    customPrice: value == 'pay_per_session'
                        ? data.customPrice
                        : null,
                    notes: data.notes,
                  );
              ref.invalidate(clientFinancialSummaryProvider(userId));
            },
          ),
        ],
      ),
    );
  }

  Widget _packageCard(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientPackageSummary p,
  ) => _planCard(
    icon: Icons.confirmation_number_outlined,
    color: const Color(0xFF7C3AED),
    title: p.label,
    subtitle: p.expiresAt == null
        ? 'Nessuna scadenza'
        : 'Scade il ${_date(p.expiresAt!)}',
    value: '${p.remaining}/${p.total}',
    progress: p.progress,
    onCancel: () => _cancelPackage(context, ref, userId, p),
  );

  Widget _membershipCard(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientMembershipSummary m,
  ) => _planCard(
    icon: Icons.calendar_month_outlined,
    color: AppColors.green600,
    title: m.label,
    subtitle:
        '${_date(m.periodStart)} → ${_date(m.periodEnd)}${m.autoRenew ? ' · rinnovo attivo' : ''}',
    value: m.lessonsQuota == null
        ? '∞'
        : '${m.lessonsQuota! - m.lessonsUsed}/${m.lessonsQuota}',
    progress: m.lessonsQuota == null
        ? 1
        : ((m.lessonsQuota! - m.lessonsUsed) / m.lessonsQuota!).clamp(0, 1),
    onCancel: () => _cancelMembership(context, ref, userId, m),
  );

  Widget _planCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String value,
    required double progress,
    required VoidCallback onCancel,
  }) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: color.withValues(alpha: .2)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            PopupMenuButton<String>(
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'cancel', child: Text('Disattiva')),
              ],
              onSelected: (_) => onCancel(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 7,
            backgroundColor: color.withValues(alpha: .08),
            color: color,
          ),
        ),
      ],
    ),
  );

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => OutlinedButton.icon(
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );

  Future<void> _editBillingTerms(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientFinancialSummary data,
  ) async {
    final priceController = TextEditingController(
      text: data.customPrice?.toStringAsFixed(2).replaceAll('.', ','),
    );
    final notesController = TextEditingController(text: data.notes ?? '');
    String? validationError;

    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Condizioni economiche'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (data.model == 'pay_per_session') ...[
                  TextField(
                    controller: priceController,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Prezzo personalizzato a lezione',
                      prefixText: '€ ',
                      hintText: 'Vuoto = tariffa standard',
                      errorText: validationError,
                    ),
                  ),
                  const SizedBox(height: 16),
                ] else
                  const Text(
                    'Il prezzo a lezione è disponibile solo con il modello “Pagamento a lezione”.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                  ),
                TextField(
                  controller: notesController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Note amministrative',
                    hintText: 'Accordi, eccezioni o promemoria interni',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () {
                final raw = priceController.text.trim().replaceAll(',', '.');
                final price = raw.isEmpty ? null : double.tryParse(raw);
                if (raw.isNotEmpty && (price == null || price < 0)) {
                  setState(
                    () => validationError = 'Inserisci un importo valido',
                  );
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              child: const Text('Salva'),
            ),
          ],
        ),
      ),
    );

    if (save != true) {
      priceController.dispose();
      notesController.dispose();
      return;
    }
    final rawPrice = priceController.text.trim().replaceAll(',', '.');
    final price = rawPrice.isEmpty ? null : double.parse(rawPrice);
    final notes = notesController.text.trim();
    priceController.dispose();
    notesController.dispose();

    await ref
        .read(clientOperationsRepositoryProvider)
        .setBillingModel(
          userId: userId,
          model: data.model,
          customPrice: data.model == 'pay_per_session' ? price : null,
          notes: notes.isEmpty ? null : notes,
        );
    ref.invalidate(clientFinancialSummaryProvider(userId));
  }

  Future<void> _sale(
    BuildContext context,
    WidgetRef ref,
    ClientSaleKind kind,
  ) async {
    final done = await showClientSaleSheet(
      context,
      ref,
      client: client,
      initialKind: kind,
    );
    if (done == true && client.userId != null) {
      ref.invalidate(clientFinancialSummaryProvider(client.userId!));
    }
  }

  Future<void> _archive(
    BuildContext context,
    WidgetRef ref,
    String userId,
    bool archived,
  ) async {
    final ok = await _confirm(
      context,
      archived
          ? 'Riattivare il cliente e consentire nuove prenotazioni?'
          : 'Archiviare il cliente? Non potrà effettuare nuove prenotazioni.',
    );
    if (!ok) return;
    await ref
        .read(clientOperationsRepositoryProvider)
        .setArchived(userId, !archived);
    ref.invalidate(clientFinancialSummaryProvider(userId));
    ref.invalidate(adminProfilesProvider);
  }

  Future<void> _reset(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) async {
    final ok = await _confirm(
      context,
      'Azzera prenotazioni, pacchetti e abbonamenti? Il profilo e il ledger degli incassi resteranno conservati.',
    );
    if (!ok) return;
    await ref.read(clientOperationsRepositoryProvider).resetClientData(userId);
    ref.invalidate(clientFinancialSummaryProvider(userId));
    ref.invalidate(adminBookingsProvider);
  }

  Future<void> _cancelPackage(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientPackageSummary p,
  ) async {
    if (!await _confirm(
      context,
      'Disattivare “${p.label}”? Le lezioni residue non saranno più utilizzabili.',
    )) {
      return;
    }
    await ref.read(clientOperationsRepositoryProvider).cancelPackage(p.id);
    ref.invalidate(clientFinancialSummaryProvider(userId));
  }

  Future<void> _cancelMembership(
    BuildContext context,
    WidgetRef ref,
    String userId,
    ClientMembershipSummary m,
  ) async {
    if (!await _confirm(context, 'Disattivare “${m.label}” e il rinnovo?')) {
      return;
    }
    await ref.read(clientOperationsRepositoryProvider).cancelMembership(m.id);
    ref.invalidate(clientFinancialSummaryProvider(userId));
  }

  Future<bool> _confirm(BuildContext context, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Conferma operazione'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annulla'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Conferma'),
            ),
          ],
        ),
      ) ??
      false;

  static String _money(double value) => value
      .toStringAsFixed(value == value.roundToDouble() ? 0 : 2)
      .replaceAll('.', ',');

  static String _billingLabel(String model) => const {
    'pay_per_session': 'A entrata',
    'package': 'Pacchetto',
    'monthly': 'Mensile',
    'quarterly': 'Trimestrale',
    'annual': 'Annuale',
    'free': 'Gratuito',
  }[model] ?? model;
  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

enum _HealthTone { ok, warning, danger }
