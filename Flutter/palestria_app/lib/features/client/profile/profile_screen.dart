import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/normalize.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/models/client_payment.dart';
import '../../../core/models/user_profile.dart';
import '../../../core/org/org_settings_service.dart';
import '../../../core/theme/org_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/ui_kit.dart';
import '../../shared/area_switch.dart';
import '../booking/booking_card.dart';
import '../booking/booking_providers.dart';
import 'billing_status.dart';
import 'edit_profile_sheet.dart';
import 'weekly_chart_sheet.dart';

/// Profilo cliente (port di prenotazioni.html §7): hero gradiente scuro→viola,
/// warning cert/anagrafica, card stato pagamenti e le tre sezioni
/// **Prossime / Passate / Transazioni** (queste ultime dal ledger `payments`).
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  /// 0 = Prossime, 1 = Passate, 2 = Transazioni.
  int _tab = 0;
  int _visible = 5;

  void _selectTab(int i) => setState(() {
        _tab = i;
        _visible = 5;
      });

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(userProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo'),
        actions: const [AdminAreaButton()],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Errore di caricamento: $e')),
        data: (p) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(userProfileProvider);
            ref.invalidate(clientBillingStatusProvider);
            ref.invalidate(ownBookingsProvider);
            ref.invalidate(ownPaymentsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              if (p != null) ...[
                _hero(context, p),
                const SizedBox(height: AppSpacing.md),
                ..._warnings(context, p),
                _billingCard(),
                const SizedBox(height: AppSpacing.md),
                _tabsBar(),
                const SizedBox(height: AppSpacing.md),
                ..._tabContent(),
                const SizedBox(height: AppSpacing.md),
                OutlinedButton.icon(
                  onPressed: () => showWeeklyChart(context),
                  icon: const Icon(Icons.bar_chart, size: 18),
                  label: const Text('I miei allenamenti'),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              OutlinedButton(
                onPressed: () async {
                  await ref.read(authRepositoryProvider).logout();
                  await ref.read(orgBrandingProvider.notifier).reset();
                  if (context.mounted) context.go('/login');
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger),
                ),
                child: const Text('Esci'),
              ),
              const SizedBox(height: AppSpacing.xxxl),
            ],
          ),
        ),
      ),
    );
  }

  /// Hero profilo (§7.1): hero scura condivisa (`DarkHero`) con avatar brand,
  /// **nome e cognome** e bottone modifica.
  Widget _hero(BuildContext context, UserProfile p) {
    final fullName = p.name.trim();
    final initial = fullName.isEmpty ? '?' : fullName[0].toUpperCase();
    return DarkHero(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: brandGradient(context),
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              fullName.isEmpty ? '—' : fullName,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          IconButton(
            onPressed: () => showEditProfileSheet(context, ref, p),
            style: IconButton.styleFrom(
              backgroundColor: const Color(0x1FFFFFFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.edit, size: 16, color: Colors.white),
            tooltip: 'Modifica profilo',
          ),
        ],
      ),
    );
  }

  /// Warning anagrafica/certificato (§7.2), possono cumularsi.
  List<Widget> _warnings(BuildContext context, UserProfile p) {
    final warnings = <Widget>[];

    Widget banner(String text, {required bool expired, VoidCallback? onTap}) =>
        GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: 11),
            decoration: BoxDecoration(
              color: expired ? AppColors.dangerSurface : AppColors.warnSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: expired ? AppColors.dangerDark : AppColors.amber,
                  width: 4,
                ),
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: expired ? AppColors.dangerDark : AppColors.docWarnText,
              ),
            ),
          ),
        );

    final anagraficaOk = isAnagraficaComplete(
      whatsapp: p.whatsapp,
      codiceFiscale: p.codiceFiscale,
      indirizzoVia: p.indirizzoVia,
      indirizzoPaese: p.indirizzoPaese,
      indirizzoCap: p.indirizzoCap,
    );
    if (!anagraficaOk) {
      warnings.add(banner('📋 Completa anagrafica',
          expired: false,
          onTap: () => showEditProfileSheet(context, ref, p)));
    }

    // Il warning "Imposta" ha senso solo se il cliente può davvero
    // impostare la scadenza (setting org 'cert_scadenza_editable').
    final certEditable = ref
            .watch(orgSettingsProvider)
            .value
            ?.getBool('cert_scadenza_editable', true) ??
        true;
    if (p.medicalCertExpiry == null) {
      if (certEditable) {
        warnings.add(banner('📋 Imposta Cert. Medico',
            expired: false,
            onTap: () => showEditProfileSheet(context, ref, p)));
      }
    } else {
      // Normalizza "oggi" e la scadenza a mezzanotte PRIMA del diff:
      // altrimenti l'ora corrente del giorno fa "perdere" un giorno
      // (mostrando es. "-1 giorno") per gran parte della giornata.
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final expiry = p.medicalCertExpiry!;
      final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
      final days = expiryDay.difference(today).inDays;
      if (days < 0) {
        warnings.add(banner('⚠️ Certificato medico scaduto', expired: true));
      } else if (days <= 30) {
        warnings.add(banner(
            '⏳ Cert. medico scade fra $days giorn${days == 1 ? 'o' : 'i'}',
            expired: false));
      }
    }
    return warnings;
  }

  /// Card stato pagamenti (§7.3).
  Widget _billingCard() {
    final statusAsync = ref.watch(clientBillingStatusProvider);
    final status = statusAsync.value;
    if (status == null) return const SizedBox.shrink();

    final (border, bg) = switch (status.tone) {
      'ok' => (AppColors.green500, AppColors.successSurface),
      'warn' => (AppColors.amber, AppColors.warnSurface),
      _ => (AppColors.border, AppColors.surface),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 1.5),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Text(status.icon, style: const TextStyle(fontSize: 25)),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(status.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.darkBg)),
                Text(status.detail,
                    style: const TextStyle(
                        fontSize: 13.5, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pill-bar Prossime / Passate / Transazioni (stile .preno-tabs web).
  Widget _tabsBar() {
    final primary = Theme.of(context).colorScheme.primary;

    Widget tab(String label, int index) => Expanded(
          child: GestureDetector(
            onTap: () => _selectTab(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: _tab == index ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
                boxShadow: _tab == index
                    ? [
                        BoxShadow(
                            color: primary.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3)),
                      ]
                    : null,
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: _tab == index ? Colors.white : AppColors.muted,
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab('Prossime', 0),
          tab('Passate', 1),
          tab('Transazioni', 2),
        ],
      ),
    );
  }

  List<Widget> _tabContent() =>
      _tab == 2 ? _transactionsContent() : _bookingsContent(upcoming: _tab == 0);

  /// Contenuto Prossime/Passate: card prenotazioni con paginazione 5 → +20.
  List<Widget> _bookingsContent({required bool upcoming}) {
    final bookingsAsync = ref.watch(ownBookingsProvider);
    final config =
        ref.watch(scheduleConfigProvider).value ?? OrgScheduleConfig.empty();

    return bookingsAsync.when(
      loading: () => const [
        Padding(padding: EdgeInsets.all(AppSpacing.xl), child: AppLoading()),
      ],
      error: (e, _) => [
        AppErrorRetry(onRetry: () => ref.invalidate(ownBookingsProvider)),
      ],
      data: (all) {
        final now = DateTime.now();
        final list = all
            .where((b) => upcoming
                ? lessonStart(b.date, b.time).isAfter(now)
                : !lessonStart(b.date, b.time).isAfter(now))
            .toList()
          ..sort((a, b) => upcoming
              ? lessonStart(a.date, a.time)
                  .compareTo(lessonStart(b.date, b.time))
              : lessonStart(b.date, b.time)
                  .compareTo(lessonStart(a.date, a.time)));

        final visible = list.take(_visible).toList();
        final remaining = list.length - visible.length;

        if (visible.isEmpty) {
          return [
            AppCard(
              padding: EdgeInsets.zero,
              child: AppEmptyState(
                title: upcoming
                    ? 'Nessuna prenotazione futura.'
                    : 'Nessuna prenotazione passata.',
                compact: true,
              ),
            ),
          ];
        }

        return [
          for (final b in visible)
            BookingCard(booking: b, config: config, showCancel: upcoming),
          if (remaining > 0) _showMoreButton(remaining),
        ];
      },
    );
  }

  /// Contenuto Transazioni: storico dal ledger `payments` (5 → +20).
  List<Widget> _transactionsContent() {
    final paymentsAsync = ref.watch(ownPaymentsProvider);

    return paymentsAsync.when(
      loading: () => const [
        Padding(padding: EdgeInsets.all(AppSpacing.xl), child: AppLoading()),
      ],
      error: (e, _) => [
        AppErrorRetry(onRetry: () => ref.invalidate(ownPaymentsProvider)),
      ],
      data: (all) {
        final visible = all.take(_visible).toList();
        final remaining = all.length - visible.length;

        if (visible.isEmpty) {
          return [
            const AppCard(
              padding: EdgeInsets.zero,
              child: AppEmptyState(
                title: 'Nessuna transazione.',
                compact: true,
              ),
            ),
          ];
        }

        return [
          for (final p in visible) _transactionCard(p),
          if (remaining > 0) _showMoreButton(remaining),
        ];
      },
    );
  }

  Widget _showMoreButton(int remaining) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: OutlinedButton(
        onPressed: () => setState(() => _visible += 20),
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: AppColors.borderGray, width: 1.5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text('Mostra altro ($remaining)'),
      ),
    );
  }

  Widget _transactionCard(ClientPayment p) {
    final cur = ref.watch(orgSettingsProvider).value?.getString(
              'locale.currency',
              'EUR',
            ) ??
        'EUR';
    final sym = cur == 'EUR' ? '€' : '$cur ';
    final color = _kindColor(p.kind);
    final period = (p.periodStart != null && p.periodEnd != null)
        ? 'Periodo: ${_fmtDate(p.periodStart)} – ${_fmtDate(p.periodEnd)}'
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: color, width: 5)),
        boxShadow: AppShadows.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_kindLabel(p.kind),
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w700)),
              ),
              Text(
                '$sym${p.amount.toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.navy,
                    fontFeatures: AppText.tabularNums),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              const Icon(Icons.calendar_today_outlined,
                  size: 13, color: AppColors.muted),
              const SizedBox(width: 6),
              Text(_fmtDate(p.createdAt),
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.muted)),
              const Spacer(),
              Text(_methodLabel(p.method),
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.subtle)),
            ],
          ),
          if (period != null) ...[
            const SizedBox(height: 4),
            Text(period,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.subtle)),
          ],
          if (p.note != null && p.note!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(p.note!,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.subtle)),
          ],
        ],
      ),
    );
  }

  static String _kindLabel(String kind) => switch (kind) {
        'session' => 'Lezione',
        'membership' => 'Abbonamento',
        'package_purchase' => 'Pacchetto',
        'penalty_mora' => 'Mora',
        'adjustment' => 'Rettifica',
        _ => 'Pagamento',
      };

  static String _methodLabel(String method) => switch (method) {
        'contanti' => '💵 Contanti',
        'contanti-report' => '🧾 Contanti (Report)',
        'carta' => '💳 Carta',
        'iban' => '🏦 Bonifico',
        'stripe' => '💳 Stripe',
        'gratuito' => '🎁 Gratuito',
        _ => method,
      };

  static Color _kindColor(String kind) => switch (kind) {
        'session' => AppColors.navy,
        'membership' => AppColors.green500,
        'package_purchase' => AppColors.amber,
        'penalty_mora' => AppColors.danger,
        _ => AppColors.subtle,
      };

  static String _fmtDate(DateTime? d) => d == null
      ? ''
      : '${d.day.toString().padLeft(2, '0')}/'
          '${d.month.toString().padLeft(2, '0')}/${d.year}';
}
