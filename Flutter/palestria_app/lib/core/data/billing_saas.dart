import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_providers.dart';

/// Entitlements della org dalla subscription SaaS (RPC get_tenant_entitlements).
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.status,
    this.maxClients,
    this.trialEnd,
    this.currentPeriodEnd,
    this.clientsCount = 0,
  });

  final String plan;
  final String status;
  final int? maxClients;
  final DateTime? trialEnd;
  final DateTime? currentPeriodEnd;
  final int clientsCount;

  bool get isActive => status == 'trialing' || status == 'active';
  bool get isTrialing => status == 'trialing';

  static Entitlements fromJson(Map<String, dynamic> json) => Entitlements(
        plan: (json['plan'] as String?) ?? 'starter',
        status: (json['status'] as String?) ?? 'trialing',
        maxClients: (json['max_clients'] as num?)?.toInt(),
        trialEnd: _date(json['trial_end']),
        currentPeriodEnd: _date(json['current_period_end']),
        clientsCount: (json['clients_count'] as num?)?.toInt() ?? 0,
      );

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());
}

/// I 3 piani SaaS (CLAUDE.md §1).
class SaasPlan {
  const SaasPlan(this.code, this.name, this.price, this.maxClientsLabel);
  final String code;
  final String name;
  final String price;
  final String maxClientsLabel;

  static const all = [
    SaasPlan('starter', 'Starter', '€39,99/mese', 'fino a 50 clienti'),
    SaasPlan('pro', 'Pro', '€79,99/mese', 'fino a 200 clienti'),
    SaasPlan('business', 'Business', '€149,99/mese', 'clienti illimitati'),
  ];
}

final entitlementsProvider = FutureProvider<Entitlements?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return null;
  final res = await ref
      .read(supabaseProvider)
      .rpc('get_tenant_entitlements')
      .timeout(const Duration(seconds: 12));
  if (res == null) return null;
  return Entitlements.fromJson((res as Map).cast<String, dynamic>());
});

class BillingSaasService {
  BillingSaasService(this._ref);
  final Ref _ref;

  /// Apre lo Stripe Checkout (abbonamento SaaS) su browser esterno.
  /// I pagamenti restano sul web per evitare i vincoli IAP del Play Store.
  Future<String?> openCheckout(String planCode) async {
    try {
      final res = await _ref.read(supabaseProvider).functions.invoke(
            'billing-checkout',
            body: {'plan_code': planCode},
          );
      final url = (res.data as Map?)?['url'] as String?;
      if (url == null) return 'Nessun URL di pagamento ricevuto.';
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      return ok ? null : 'Impossibile aprire la pagina di pagamento.';
    } catch (e) {
      return 'Errore: $e';
    }
  }

  /// Apre lo Stripe Customer Portal (gestione abbonamento) su browser esterno.
  Future<String?> openPortal() async {
    try {
      final res = await _ref
          .read(supabaseProvider)
          .functions
          .invoke('billing-portal');
      final url = (res.data as Map?)?['url'] as String?;
      if (url == null) return 'Nessun URL ricevuto.';
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      return ok ? null : 'Impossibile aprire il portale.';
    } catch (e) {
      return 'Errore: $e';
    }
  }
}

final billingSaasServiceProvider =
    Provider<BillingSaasService>((ref) => BillingSaasService(ref));
