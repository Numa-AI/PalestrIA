import 'package:flutter_test/flutter_test.dart';
import 'package:palestria_app/core/data/client_operations.dart';
import 'package:palestria_app/core/data/booking_repository.dart';

void main() {
  test('booking errors expose actionable billing messages', () {
    expect(
      BookingRepository.bookSlotErrorMessage('outstanding_balance'),
      contains('pagamenti in sospeso'),
    );
    expect(
      BookingRepository.bookSlotErrorMessage('client_archived'),
      contains('archiviato'),
    );
    expect(
      BookingRepository.bookSlotErrorMessage('client_not_found'),
      contains('cliente selezionato'),
    );
  });
  test('financial summary parses package, membership and health', () {
    final summary = ClientFinancialSummary.fromJson({
      'billing_profile': {
        'model': 'package',
        'custom_price': 18.5,
        'notes': 'Cliente storico',
      },
      'packages': [
        {
          'id': 'pkg-1',
          'label': 'Carnet 10',
          'total_sessions': 10,
          'remaining_sessions': 3,
          'status': 'active',
          'price': 150,
        },
      ],
      'memberships': [
        {
          'id': 'mem-1',
          'plan_label': 'Mensile',
          'period_start': '2099-01-01',
          'period_end': '2099-01-31',
          'lessons_used': 2,
          'lessons_quota': 8,
          'status': 'active',
          'auto_renew': true,
          'price': 90,
        },
      ],
      'payments': const [],
      'totals': {'collected': 240, 'unpaid': 36, 'unpaid_count': 2},
      'health': {
        'archived': false,
        'medical_cert_expired': true,
        'insurance_expired': false,
        'active_package': true,
        'active_membership': false,
        'unpaid_over_threshold': true,
      },
    });

    expect(summary.model, 'package');
    expect(summary.customPrice, 18.5);
    expect(summary.activePackage?.remaining, 3);
    expect(summary.activePackage?.progress, closeTo(.3, .001));
    expect(summary.memberships.single.lessonsQuota, 8);
    expect(summary.collected, 240);
    expect(summary.unpaidCount, 2);
    expect(summary.health.hasBlockingIssue, isTrue);
    expect(summary.health.hasWarning, isTrue);
  });

  test('inactive package is not selected as active', () {
    final summary = ClientFinancialSummary.fromJson({
      'billing_profile': {'model': 'package'},
      'packages': [
        {
          'id': 'pkg-1',
          'label': 'Terminato',
          'total_sessions': 5,
          'remaining_sessions': 0,
          'status': 'exhausted',
        },
      ],
      'memberships': const [],
      'payments': const [],
      'totals': const {},
      'health': const {'billing_coverage_missing': true},
    });
    expect(summary.activePackage, isNull);
    expect(summary.health.billingCoverageMissing, isTrue);
    expect(summary.health.hasBlockingIssue, isTrue);
  });
}
