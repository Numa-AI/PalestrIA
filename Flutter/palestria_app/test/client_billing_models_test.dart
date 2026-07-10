import 'package:flutter_test/flutter_test.dart';
import 'package:palestria_app/core/data/client_billing_models.dart';

void main() {
  test('le durate non diventano modelli di pagamento distinti', () {
    expect(
      effectiveBillingModel({
        'default_model': 'monthly',
        'default_membership_period': 'annual',
      }),
      'monthly',
    );
    expect(
      effectiveBillingModel(
        {'default_model': 'monthly', 'default_membership_period': 'monthly'},
        {'model_override': 'monthly', 'membership_period_override': 'quarterly'},
      ),
      'monthly',
    );
  });

  test('calcola la fine mensile, trimestrale e annuale', () {
    final start = DateTime(2026, 2, 10);
    expect(membershipPeriodEnd(start, 'monthly'), DateTime(2026, 3, 10));
    expect(membershipPeriodEnd(start, 'quarterly'), DateTime(2026, 5, 10));
    expect(membershipPeriodEnd(start, 'annual'), DateTime(2027, 2, 10));
  });
}
