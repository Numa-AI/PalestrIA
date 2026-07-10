import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_providers.dart';
import '../org/org_settings_service.dart';
import '../security/external_url.dart';

/// Entitlements della org dalla subscription SaaS (RPC get_tenant_entitlements).
class Entitlements {
  const Entitlements({
    required this.plan,
    required this.status,
    this.maxClients,
    this.trialEnd,
    this.currentPeriodEnd,
    this.clientsCount = 0,
    this.features = const {},
  });

  final String plan;
  final String status;
  final int? maxClients;
  final DateTime? trialEnd;
  final DateTime? currentPeriodEnd;
  final int clientsCount;
  final Map<String, bool> features;

  bool get isActive => status == 'trialing' || status == 'active';
  bool get isTrialing => status == 'trialing';

  static Entitlements fromJson(Map<String, dynamic> json) => Entitlements(
    plan: (json['plan'] as String?) ?? 'starter',
    status: (json['status'] as String?) ?? 'trialing',
    maxClients: (json['max_clients'] as num?)?.toInt(),
    trialEnd: _date(json['trial_end']),
    currentPeriodEnd: _date(json['current_period_end']),
    clientsCount: (json['clients_count'] as num?)?.toInt() ?? 0,
    features: ((json['features'] as Map?) ?? const {}).map(
      (key, value) => MapEntry(key.toString(), value == true),
    ),
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
      final res = await _ref
          .read(supabaseProvider)
          .functions
          .invoke('billing-checkout', body: {'plan_code': planCode});
      final url = trustedExternalUri((res.data as Map?)?['url'] as String?);
      if (url == null) return 'URL di pagamento non valido.';
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
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
      final url = trustedExternalUri((res.data as Map?)?['url'] as String?);
      if (url == null) return 'URL del portale non valido.';
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      return ok ? null : 'Impossibile aprire il portale.';
    } catch (e) {
      return 'Errore: $e';
    }
  }
}

final billingSaasServiceProvider = Provider<BillingSaasService>(
  (ref) => BillingSaasService(ref),
);

final featureEnabledProvider = FutureProvider.family<bool, String>((
  ref,
  feature,
) async {
  final entitlements = await ref.watch(entitlementsProvider.future);
  final settings = await ref.watch(orgSettingsProvider.future);
  if (entitlements == null || !entitlements.isActive) return false;
  final allowedByPlan = entitlements.features[feature] == true;
  if (!allowedByPlan) return false;
  return settings?.getBool('features.$feature', true) ?? true;
});

class FeatureGate extends ConsumerWidget {
  const FeatureGate({
    super.key,
    required this.feature,
    required this.child,
    this.message =
        'Funzione non disponibile per il piano corrente o disattivata.',
  });

  final String feature;
  final Widget child;
  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(featureEnabledProvider(feature));
    return access.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) =>
          Center(child: Text(message, textAlign: TextAlign.center)),
      data: (enabled) => enabled
          ? child
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(message, textAlign: TextAlign.center),
              ),
            ),
    );
  }
}
