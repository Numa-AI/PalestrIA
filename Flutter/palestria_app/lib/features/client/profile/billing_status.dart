import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/data/booking_pricing.dart';
import '../../../core/data/schedule_config.dart';
import '../../../core/org/org_settings_service.dart';
import '../booking/booking_providers.dart';

/// Stato pagamenti del cliente (§7.3 spec-client) — card riepilogo.
class ClientBillingStatus {
  const ClientBillingStatus({
    required this.icon,
    required this.title,
    required this.detail,
    required this.tone, // 'ok' | 'warn' | 'neutral'
  });

  final String icon;
  final String title;
  final String detail;
  final String tone;
}

final clientBillingStatusProvider = FutureProvider<ClientBillingStatus?>((
  ref,
) async {
  final session = ref.watch(sessionProvider);
  final orgContext = await ref.watch(orgContextProvider.future);
  if (session == null || orgContext.orgId == null) return null;
  final client = ref.read(supabaseProvider);
  final orgId = orgContext.orgId!;
  final userId = session.user.id;

  final results = await Future.wait<dynamic>([
    client
        .from('billing_settings')
        .select('default_model')
        .eq('org_id', orgId)
        .maybeSingle(),
    client
        .from('client_billing_profiles')
        .select('model_override')
        .eq('org_id', orgId)
        .eq('user_id', userId)
        .maybeSingle(),
    client
        .from('client_memberships')
        .select('plan_label, period_end, lessons_quota, lessons_used, status')
        .eq('org_id', orgId)
        .eq('user_id', userId)
        .eq('status', 'active')
        .gte('period_end', OrgScheduleConfig.localDateStr(DateTime.now()))
        .order('period_end', ascending: false)
        .limit(1),
    client
        .from('client_packages')
        .select('label, remaining_sessions')
        .eq('org_id', orgId)
        .eq('user_id', userId)
        .eq('status', 'active'),
  ]).timeout(const Duration(seconds: 12));

  final defaultModel =
      (results[0]?['default_model'] as String?) ?? 'pay_per_session';
  final override = results[1]?['model_override'] as String?;
  final model = override ?? defaultModel;

  switch (model) {
    case 'free':
      return const ClientBillingStatus(
        icon: '🎁',
        title: 'Accesso gratuito',
        detail: 'Nessun pagamento richiesto per le tue lezioni.',
        tone: 'ok',
      );

    case 'monthly':
      final rows = results[2] as List;
      final m = rows.isEmpty ? null : rows.first as Map<String, dynamic>;
      final active =
          m != null &&
          m['status'] == 'active' &&
          m['period_end'] != null &&
          !DateTime.parse(
            m['period_end'] as String,
          ).isBefore(DateTime.now().subtract(const Duration(days: 1)));
      if (!active) {
        return const ClientBillingStatus(
          icon: '📅',
          title: 'Abbonamento non attivo',
          detail:
              'Contatta il trainer per attivare o rinnovare l\'abbonamento mensile.',
          tone: 'warn',
        );
      }
      final end = DateTime.parse(m['period_end'] as String);
      final endStr =
          '${end.day.toString().padLeft(2, '0')}/${end.month.toString().padLeft(2, '0')}/${end.year}';
      final quota = (m['lessons_quota'] as num?)?.toInt();
      final used = (m['lessons_used'] as num?)?.toInt() ?? 0;
      final label = m['plan_label'] as String?;
      return ClientBillingStatus(
        icon: '📅',
        title:
            'Abbonamento attivo${label == null || label.isEmpty ? '' : ' · $label'}',
        detail: quota == null
            ? 'Valido fino al $endStr · lezioni illimitate'
            : 'Valido fino al $endStr · $used/$quota lezioni usate',
        tone: 'ok',
      );

    case 'package':
      final packs = (results[3] as List).cast<Map<String, dynamic>>();
      final remaining = packs.fold<int>(
        0,
        (sum, p) => sum + ((p['remaining_sessions'] as num?)?.toInt() ?? 0),
      );
      if (remaining > 0) {
        return ClientBillingStatus(
          icon: '🎫',
          title:
              'Pacchetto: $remaining ingress${remaining == 1 ? 'o rimasto' : 'i rimasti'}',
          detail:
              'Gli ingressi si scalano automaticamente a ogni prenotazione.',
          tone: 'ok',
        );
      }
      return const ClientBillingStatus(
        icon: '🎫',
        title: 'Pacchetto esaurito',
        detail: 'Contatta il trainer per acquistare un nuovo pacchetto.',
        tone: 'warn',
      );

    default: // pay_per_session
      final bookings = await ref.watch(ownBookingsProvider.future);
      final settings = await ref.watch(orgSettingsProvider.future);
      final config = await ref.watch(scheduleConfigProvider.future);
      final now = DateTime.now();
      double debt = 0;
      int unpaidCount = 0;
      for (final b in bookings) {
        if (b.paid || b.status == 'cancelled') continue;
        if (lessonStart(b.date, b.time).isAfter(now)) continue;
        // Stesso calcolo di statistiche/registro (bookingPrice, 4 livelli di
        // fallback) così l'importo "Da saldare" del cliente combacia con quello
        // che il trainer vede/incassa, invece dei soli custom_price + listino.
        debt += bookingPrice(b, settings, config);
        unpaidCount++;
      }
      if (unpaidCount > 0) {
        final debtStr = debt == debt.roundToDouble()
            ? debt.toStringAsFixed(0)
            : debt.toStringAsFixed(2).replaceAll('.', ',');
        return ClientBillingStatus(
          icon: '💳',
          title: 'Da saldare: €$debtStr',
          detail:
              '$unpaidCount lezion${unpaidCount == 1 ? 'e' : 'i'} non ancora pagat${unpaidCount == 1 ? 'a' : 'e'}.',
          tone: 'warn',
        );
      }
      return const ClientBillingStatus(
        icon: '✅',
        title: 'Pagamenti in regola',
        detail: 'Paghi ogni lezione singolarmente.',
        tone: 'ok',
      );
  }
});
