import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/normalize.dart';
import '../../../core/data/admin_repository.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/billing_realtime.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/booking.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../client/booking/booking_providers.dart';
import 'client_balance_sheet.dart';
import 'client_sale_sheet.dart';
import 'pay_debt_sheet.dart';

final adminPaymentsDefaultModelProvider = FutureProvider<String>((ref) async {
  final org = await ref.watch(orgContextProvider.future);
  if (org.orgId == null) return 'pay_per_session';
  final row = await ref
      .read(supabaseProvider)
      .from('billing_settings')
      .select('default_model')
      .eq('org_id', org.orgId!)
      .maybeSingle();
  return (row?['default_model'] as String?) ?? 'pay_per_session';
});

class ClientBalanceAccount {
  const ClientBalanceAccount({
    required this.userId,
    required this.name,
    required this.balance,
    required this.debt,
    required this.credit,
    this.email,
    this.whatsapp,
  });

  final String userId;
  final String name;
  final String? email;
  final String? whatsapp;
  final double balance;
  final double debt;
  final double credit;

  factory ClientBalanceAccount.fromRow(Map<String, dynamic> row) =>
      ClientBalanceAccount(
        userId: row['user_id'] as String,
        name: (row['name'] as String?) ?? 'Cliente',
        email: row['email'] as String?,
        whatsapp: row['whatsapp'] as String?,
        balance: (row['balance'] as num?)?.toDouble() ?? 0,
        debt: (row['debt'] as num?)?.toDouble() ?? 0,
        credit: (row['credit'] as num?)?.toDouble() ?? 0,
      );
}

final adminClientBalancesProvider = FutureProvider<List<ClientBalanceAccount>>((
  ref,
) async {
  ref.watch(billingRealtimeTickProvider);
  final result = await ref
      .read(supabaseProvider)
      .rpc('get_client_balance_overview')
      .timeout(const Duration(seconds: 20));
  return [
    for (final row in result as List)
      ClientBalanceAccount.fromRow((row as Map).cast<String, dynamic>()),
  ];
});

/// Formattatore € unico del modulo Pagamenti: virgola decimale italiana
/// (es. "12,50"), niente decimali quando l'importo è intero. Condiviso con
/// [PayDebtSheet] (che importa questo file) per evitare due copie divergenti.
String formatEuro(double v) {
  final s = v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  return s.replaceAll('.', ',');
}

/// Contatto con debito (prenotazioni passate non pagate).
class DebtorContact {
  DebtorContact({
    required this.name,
    this.whatsapp,
    this.email,
    required this.bookings,
    required this.total,
  });
  final String name;
  final String? whatsapp;
  final String? email;
  final List<Booking> bookings;
  final double total;
}

/// Tab Pagamenti (spec-admin §7): "Da incassare" (debitori) + "Incassato
/// questo mese", con popup di saldo → admin_pay_bookings.
class PaymentsTab extends ConsumerStatefulWidget {
  const PaymentsTab({super.key});

  @override
  ConsumerState<PaymentsTab> createState() => _PaymentsTabState();
}

class _PaymentsTabState extends ConsumerState<PaymentsTab> {
  bool _showDebtors = false;
  bool _showRecent = false;
  final Set<String> _openCards = {};

  @override
  Widget build(BuildContext context) {
    final bookingsAsync = ref.watch(adminBookingsProvider);
    final paymentsAsync = ref.watch(monthPaymentsProvider);
    final balancesAsync = ref.watch(adminClientBalancesProvider);
    final modelAsync = ref.watch(adminPaymentsDefaultModelProvider);
    final billingModel = modelAsync.value ?? 'pay_per_session';
    final (operationIcon, operationLabel) = switch (billingModel) {
      'package' => (Icons.confirmation_number_outlined, 'Vendi pacchetto'),
      'monthly' => (Icons.calendar_month_outlined, 'Vendi abbonamento'),
      'free' => (Icons.money_off_outlined, 'Modello gratuito'),
      _ => (Icons.account_balance_wallet_outlined, 'Conto cliente'),
    };
    return bookingsAsync.when(
      loading: () => const AppLoading(),
      error: (e, _) => AppErrorRetry(
        message: 'Errore nel caricamento dei pagamenti.',
        onRetry: () => ref.invalidate(adminBookingsProvider),
      ),
      data: (bookings) {
        final accounts = balancesAsync.value ?? const <ClientBalanceAccount>[];
        final debtors = accounts.where((account) => account.debt > 0).toList();
        final totalUnpaid = debtors.fold<double>(0, (s, d) => s + d.debt);
        final payments = paymentsAsync.value ?? const <PaymentRow>[];
        final monthRevenue = payments.fold<double>(0, (s, p) => s + p.amount);

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(adminBookingsProvider);
            ref.invalidate(monthPaymentsProvider);
            ref.invalidate(adminClientBalancesProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              100,
            ),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Pagamenti', style: AppText.pageTitle),
                  ),
                  FilledButton.icon(
                    onPressed: modelAsync.isLoading || billingModel == 'free'
                        ? null
                        : () => _newOperation(billingModel, bookings),
                    icon: Icon(operationIcon, size: 18),
                    label: Text(operationLabel),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  _statCard(
                    '💰',
                    'Da Incassare',
                    '€${formatEuro(totalUnpaid)}',
                    AppColors.danger,
                    subtitle: debtors.isEmpty
                        ? null
                        : '${debtors.length} '
                              '${debtors.length == 1 ? 'debitore' : 'debitori'}',
                    active: _showDebtors,
                    onTap: () => setState(() {
                      _showDebtors = !_showDebtors;
                      if (_showDebtors) _showRecent = false;
                    }),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _statCard(
                    '💳',
                    'Incassato questo mese',
                    '€${formatEuro(monthRevenue)}',
                    AppColors.green600,
                    subtitle: payments.isEmpty
                        ? null
                        : '${payments.length} '
                              '${payments.length == 1 ? 'pagamento' : 'pagamenti'}',
                    active: _showRecent,
                    onTap: () => setState(() {
                      _showRecent = !_showRecent;
                      if (_showRecent) _showDebtors = false;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_showDebtors) _balanceDebtorsList(debtors),
              if (_showRecent) _recentList(payments),
            ],
          ),
        );
      },
    );
  }

  // Compatibilità con il popup calendario legacy; la tab usa il conto server.
  // ignore: unused_element
  List<DebtorContact> _computeDebtors(
    List<Booking> bookings, {
    bool includeFuture = false,
  }) {
    final now = DateTime.now();
    // Stesso prezzo del server (admin_pay_bookings = custom ?? default tipo) e
    // di analytics/registro: senza questo, i pay-per-session senza custom_price
    // valgono €0 e sparivano dalla lista debitori pur dovendo il prezzo pieno.
    final settings = ref.read(orgSettingsProvider).value;
    final config = ref.read(scheduleConfigProvider).value;
    final byKey = <String, DebtorContact>{};
    final order = <String>[];

    String keyOf(String? email, String? whatsapp) {
      if (email != null && email.isNotEmpty) return 'e:${email.toLowerCase()}';
      if (whatsapp != null && whatsapp.isNotEmpty) {
        return 'p:${normalizePhone(whatsapp)}';
      }
      return 'x:${identityHashCode(whatsapp)}';
    }

    for (final b in bookings) {
      if (b.paid ||
          b.isBillingVoided ||
          b.status == 'cancelled' ||
          b.status == 'cancellation_requested') {
        continue;
      }
      if (!includeFuture && lessonStart(b.date, b.time).isAfter(now)) continue;
      final price = bookingPrice(b, settings, config);
      final k = keyOf(b.email, b.whatsapp);
      final existing = byKey[k];
      if (existing == null) {
        byKey[k] = DebtorContact(
          name: b.name ?? '—',
          whatsapp: b.whatsapp,
          email: b.email,
          bookings: [b],
          total: price,
        );
        order.add(k);
      } else {
        byKey[k] = DebtorContact(
          name: existing.name,
          whatsapp: existing.whatsapp ?? b.whatsapp,
          email: existing.email ?? b.email,
          bookings: [...existing.bookings, b],
          total: existing.total + price,
        );
      }
    }
    final list =
        [for (final k in order) byKey[k]!].where((d) => d.total > 0).toList()
          ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  Widget _statCard(
    String emoji,
    String label,
    String value,
    Color color, {
    required bool active,
    required VoidCallback onTap,
    String? subtitle,
  }) {
    return Expanded(
      child: AppCard(
        onTap: onTap,
        radius: AppRadius.cardLg,
        borderColor: active ? color : const Color(0x0F000000),
        elevated: active,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(emoji, style: const TextStyle(fontSize: 20)),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: Color(0xFF9CA3AF),
              ),
            ),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: AppText.tabularNums,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.subtle,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _balanceDebtorsList(List<ClientBalanceAccount> debtors) {
    if (debtors.isEmpty) {
      return const AppEmptyState(
        compact: true,
        icon: Icons.celebration_outlined,
        title: 'Nessun cliente con pagamenti in sospeso! 🎉',
      );
    }
    return Column(
      children: [
        for (final account in debtors)
          AppCard(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            leftBarColor: AppColors.danger,
            borderColor: AppColors.borderGray,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        account.whatsapp ?? account.email ?? '—',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: AppColors.muted,
                        ),
                      ),
                      Text(
                        'Debito conto: €${formatEuro(account.debt)}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () => _recordBalance(
                    ClientBalanceOperation.payment,
                    userId: account.userId,
                    amount: account.debt,
                  ),
                  child: const Text('Incassa'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Compatibilità con showPayDebtSheet finché i call-site calendario non migrano.
  // ignore: unused_element
  Widget _debtorsList(OrgScheduleConfig config, List<DebtorContact> debtors) {
    if (debtors.isEmpty) {
      return const AppEmptyState(
        compact: true,
        icon: Icons.celebration_outlined,
        title: 'Nessun cliente con pagamenti in sospeso! 🎉',
      );
    }
    return Column(
      children: [
        for (var i = 0; i < debtors.length; i++)
          _debtorCard(config, debtors[i], i),
      ],
    );
  }

  Widget _debtorCard(OrgScheduleConfig config, DebtorContact d, int index) {
    final open = _openCards.contains('$index');
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: EdgeInsets.zero,
      leftBarColor: AppColors.danger,
      borderColor: AppColors.borderGray,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              open ? _openCards.remove('$index') : _openCards.add('$index');
            }),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          d.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '📱 ${d.whatsapp ?? '—'}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.danger.withValues(alpha: 0x14 / 255),
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                    child: Text(
                      'Da incassare: €${formatEuro(d.total)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                children: [
                  for (final b in d.bookings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '📅 ${_shortDate(b.date)} · 🕐 ${b.time} · ${config.slotName(b.slotType)}',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          Text(
                            '€${formatEuro(bookingPrice(b, ref.read(orgSettingsProvider).value, config))}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton(
                    onPressed: () => _payDebt(d),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                    ),
                    child: const Text('✓ Segna come pagato'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recentList(List<PaymentRow> payments) {
    if (payments.isEmpty) {
      return const AppEmptyState(
        compact: true,
        icon: Icons.receipt_long_outlined,
        title: 'Nessun pagamento registrato',
      );
    }
    return Column(
      children: [
        for (final p in payments)
          AppCard(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.all(AppSpacing.md),
            borderColor: AppColors.borderGray,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.clientEmail ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        '📅 ${p.createdAt == null ? '' : _shortDate(p.createdAt!.toIso8601String().substring(0, 10))} · ${PaymentRow.kindLabels[p.kind] ?? p.kind} · ${PaymentRow.methodLabels[p.method] ?? p.method}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.green500.withValues(alpha: 0x14 / 255),
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    '€${formatEuro(p.amount)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.green600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _payDebt(DebtorContact d) async {
    final paid = await showPayDebtSheet(context, ref, d);
    if (paid == true) {
      ref.invalidate(adminBookingsProvider);
      ref.invalidate(monthPaymentsProvider);
    }
  }

  Future<void> _newOperation(String model, List<Booking> bookings) async {
    if (model == 'package' || model == 'monthly') {
      final done = await showClientSaleSheet(
        context,
        ref,
        initialKind: model == 'package'
            ? ClientSaleKind.package
            : ClientSaleKind.membership,
        lockKind: true,
      );
      if (done == true) {
        ref.invalidate(adminBookingsProvider);
        ref.invalidate(monthPaymentsProvider);
      }
      return;
    }

    final operation = await showModalBottomSheet<ClientBalanceOperation>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Lezioni a entrata',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppSpacing.sm),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
              title: const Text('Incassa saldo'),
              subtitle: const Text('Riduce il debito o crea credito residuo'),
              onTap: () => Navigator.pop(ctx, ClientBalanceOperation.payment),
            ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.add_card_outlined)),
              title: const Text('Aggiungi credito'),
              subtitle: const Text('Versamento anticipato o credito omaggio'),
              onTap: () => Navigator.pop(ctx, ClientBalanceOperation.credit),
            ),
            ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.remove_circle_outline),
              ),
              title: const Text('Aggiungi debito'),
              subtitle: const Text('Addebito manuale extra sul conto'),
              onTap: () => Navigator.pop(ctx, ClientBalanceOperation.debt),
            ),
          ],
        ),
      ),
    );
    if (operation != null && mounted) await _recordBalance(operation);
  }

  Future<void> _recordBalance(
    ClientBalanceOperation operation, {
    String? userId,
    double? amount,
  }) async {
    final done = await showClientBalanceSheet(
      context,
      operation: operation,
      initialUserId: userId,
      initialAmount: amount,
    );
    if (done == true) {
      ref.invalidate(adminClientBalancesProvider);
      ref.invalidate(monthPaymentsProvider);
      ref.invalidate(adminBookingsProvider);
    }
  }

  static String _shortDate(String ymd) {
    final d = DateTime.parse(ymd);
    return '${d.day}/${d.month}';
  }
}
