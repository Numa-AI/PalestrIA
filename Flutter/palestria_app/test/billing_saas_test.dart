import 'package:flutter_test/flutter_test.dart';
import 'package:palestria_app/core/data/billing_saas.dart';

void main() {
  test('Entitlements legge feature e stato del piano', () {
    final entitlements = Entitlements.fromJson({
      'plan': 'pro',
      'status': 'active',
      'features': {
        'workout_plans': true,
        'ai_reports': true,
        'client_online_payments': false,
      },
      'clients_count': 12,
    });

    expect(entitlements.isActive, isTrue);
    expect(entitlements.features['ai_reports'], isTrue);
    expect(entitlements.features['client_online_payments'], isFalse);
    expect(entitlements.clientsCount, 12);
  });

  test('Entitlements non inventa feature assenti', () {
    final entitlements = Entitlements.fromJson({
      'plan': 'starter',
      'status': 'trialing',
    });

    expect(entitlements.isActive, isTrue);
    expect(entitlements.features, isEmpty);
  });
}
