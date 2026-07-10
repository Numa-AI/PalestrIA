import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import 'admin_repository.dart';

class ClientPackageSummary {
  const ClientPackageSummary({
    required this.id,
    required this.label,
    required this.total,
    required this.remaining,
    required this.status,
    this.expiresAt,
    this.price = 0,
  });
  final String id;
  final String label;
  final int total;
  final int remaining;
  final String status;
  final DateTime? expiresAt;
  final double price;

  double get progress => total <= 0 ? 0 : (remaining / total).clamp(0, 1);
  bool get active => status == 'active' && remaining > 0;

  factory ClientPackageSummary.fromJson(Map<String, dynamic> row) =>
      ClientPackageSummary(
        id: row['id'] as String,
        label: (row['label'] as String?) ?? 'Pacchetto',
        total: (row['total_sessions'] as num?)?.toInt() ?? 0,
        remaining: (row['remaining_sessions'] as num?)?.toInt() ?? 0,
        status: (row['status'] as String?) ?? 'active',
        expiresAt: _date(row['expires_at']),
        price: (row['price'] as num?)?.toDouble() ?? 0,
      );
}

class ClientMembershipSummary {
  const ClientMembershipSummary({
    required this.id,
    required this.label,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    required this.lessonsUsed,
    this.lessonsQuota,
    this.autoRenew = false,
    this.price = 0,
  });
  final String id;
  final String label;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String status;
  final int lessonsUsed;
  final int? lessonsQuota;
  final bool autoRenew;
  final double price;

  bool get active {
    final today = DateTime.now();
    final d = DateTime(today.year, today.month, today.day);
    return status == 'active' &&
        !d.isBefore(periodStart) &&
        !d.isAfter(periodEnd);
  }

  factory ClientMembershipSummary.fromJson(Map<String, dynamic> row) =>
      ClientMembershipSummary(
        id: row['id'] as String,
        label: (row['plan_label'] as String?) ?? 'Abbonamento',
        periodStart: _date(row['period_start']) ?? DateTime(1970),
        periodEnd: _date(row['period_end']) ?? DateTime(1970),
        status: (row['status'] as String?) ?? 'active',
        lessonsUsed: (row['lessons_used'] as num?)?.toInt() ?? 0,
        lessonsQuota: (row['lessons_quota'] as num?)?.toInt(),
        autoRenew: row['auto_renew'] == true,
        price: (row['price'] as num?)?.toDouble() ?? 0,
      );
}

class ClientFinancialHealth {
  const ClientFinancialHealth({
    this.archived = false,
    this.medicalCertExpired = false,
    this.insuranceExpired = false,
    this.activePackage = false,
    this.activeMembership = false,
    this.unpaidOverThreshold = false,
    this.billingCoverageMissing = false,
  });
  final bool archived;
  final bool medicalCertExpired;
  final bool insuranceExpired;
  final bool activePackage;
  final bool activeMembership;
  final bool unpaidOverThreshold;
  final bool billingCoverageMissing;

  bool get hasBlockingIssue =>
      archived || unpaidOverThreshold || billingCoverageMissing;
  bool get hasWarning => medicalCertExpired || insuranceExpired;

  factory ClientFinancialHealth.fromJson(Map<String, dynamic> row) =>
      ClientFinancialHealth(
        archived: row['archived'] == true,
        medicalCertExpired: row['medical_cert_expired'] == true,
        insuranceExpired: row['insurance_expired'] == true,
        activePackage: row['active_package'] == true,
        activeMembership: row['active_membership'] == true,
        unpaidOverThreshold: row['unpaid_over_threshold'] == true,
        billingCoverageMissing: row['billing_coverage_missing'] == true,
      );
}

class ClientFinancialSummary {
  const ClientFinancialSummary({
    required this.model,
    required this.packages,
    required this.memberships,
    required this.payments,
    required this.health,
    this.customPrice,
    this.notes,
    this.collected = 0,
    this.balance = 0,
    this.debt = 0,
    this.unpaid = 0,
    this.unpaidCount = 0,
    this.scheduled = 0,
    this.credit = 0,
    this.creditCount = 0,
  });
  final String model;
  final double? customPrice;
  final String? notes;
  final List<ClientPackageSummary> packages;
  final List<ClientMembershipSummary> memberships;
  final List<PaymentRow> payments;
  final ClientFinancialHealth health;
  final double collected;
  final double balance;
  final double debt;
  final double unpaid;
  final int unpaidCount;
  final double scheduled;
  final double credit;
  final int creditCount;

  ClientPackageSummary? get activePackage {
    for (final p in packages) {
      if (p.active) return p;
    }
    return null;
  }

  ClientMembershipSummary? get activeMembership {
    for (final m in memberships) {
      if (m.active) return m;
    }
    return null;
  }

  factory ClientFinancialSummary.fromJson(Map<String, dynamic> json) {
    final billing = (json['billing_profile'] as Map? ?? const {})
        .cast<String, dynamic>();
    final totals = (json['totals'] as Map? ?? const {}).cast<String, dynamic>();
    final health = (json['health'] as Map? ?? const {}).cast<String, dynamic>();
    return ClientFinancialSummary(
      model: (billing['model'] as String?) ?? 'pay_per_session',
      customPrice: (billing['custom_price'] as num?)?.toDouble(),
      notes: billing['notes'] as String?,
      packages: [
        for (final row in (json['packages'] as List? ?? const []))
          ClientPackageSummary.fromJson((row as Map).cast<String, dynamic>()),
      ],
      memberships: [
        for (final row in (json['memberships'] as List? ?? const []))
          ClientMembershipSummary.fromJson(
            (row as Map).cast<String, dynamic>(),
          ),
      ],
      payments: [
        for (final row in (json['payments'] as List? ?? const []))
          PaymentRow.fromRow((row as Map).cast<String, dynamic>()),
      ],
      health: ClientFinancialHealth.fromJson(health),
      collected: (totals['collected'] as num?)?.toDouble() ?? 0,
      balance: (totals['balance'] as num?)?.toDouble() ?? 0,
      debt: (totals['debt'] as num?)?.toDouble() ?? 0,
      unpaid: (totals['unpaid'] as num?)?.toDouble() ?? 0,
      unpaidCount: (totals['unpaid_count'] as num?)?.toInt() ?? 0,
      scheduled: (totals['scheduled'] as num?)?.toDouble() ?? 0,
      credit: (totals['credit'] as num?)?.toDouble() ?? 0,
      creditCount: (totals['credit_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class ClientOperationsRepository {
  ClientOperationsRepository(this._client);
  final SupabaseClient _client;

  Future<ClientFinancialSummary> fetchSummary(String userId) async {
    final result = await _client
        .rpc('get_client_financial_summary', params: {'p_user_id': userId})
        .timeout(const Duration(seconds: 20));
    return ClientFinancialSummary.fromJson(
      (result as Map).cast<String, dynamic>(),
    );
  }

  Future<String> sellPackage({
    required String userId,
    required String label,
    required int sessions,
    required double price,
    required String method,
    DateTime? expiresAt,
    String? note,
    String? idempotencyKey,
  }) async {
    final result = await _client
        .rpc(
          'admin_sell_package',
          params: {
            'p_user_id': userId,
            'p_label': label,
            'p_sessions': sessions,
            'p_price': price,
            'p_method': method,
            'p_expires': expiresAt == null ? null : _ymd(expiresAt),
            'p_idempotency_key': idempotencyKey ?? operationKey('package'),
            'p_note': note,
          },
        )
        .timeout(const Duration(seconds: 30));
    return result.toString();
  }

  Future<String> sellMembership({
    required String userId,
    required String label,
    required double price,
    required DateTime periodStart,
    required DateTime periodEnd,
    required String method,
    int? lessonsQuota,
    bool autoRenew = false,
    String billingPeriod = 'monthly',
    String? note,
    String? idempotencyKey,
  }) async {
    final result = await _client
        .rpc(
          'admin_record_membership_payment',
          params: {
            'p_user_id': userId,
            'p_label': label,
            'p_price': price,
            'p_period_start': _ymd(periodStart),
            'p_period_end': _ymd(periodEnd),
            'p_lessons_quota': lessonsQuota,
            'p_method': method,
            'p_auto_renew': autoRenew,
            'p_idempotency_key': idempotencyKey ?? operationKey('membership'),
            'p_note': note,
            'p_billing_period': billingPeriod,
          },
        )
        .timeout(const Duration(seconds: 30));
    return result.toString();
  }

  Future<void> setBillingModel({
    required String userId,
    required String model,
    double? customPrice,
    String? notes,
  }) async {
    await _client
        .rpc(
          'admin_set_client_billing_model',
          params: {
            'p_user_id': userId,
            'p_model': model,
            'p_custom_price': customPrice,
            'p_notes': notes,
          },
        )
        .timeout(const Duration(seconds: 20));
  }

  Future<double> recordBalanceOperation({
    required String userId,
    required String operation,
    required double amount,
    String? method,
    String? note,
    String? idempotencyKey,
  }) async {
    final result = await _client
        .rpc(
          'admin_record_client_balance_operation',
          params: {
            'p_user_id': userId,
            'p_operation': operation,
            'p_amount': amount,
            'p_method': method,
            'p_note': note,
            'p_idempotency_key':
                idempotencyKey ?? operationKey('balance-$operation'),
          },
        )
        .timeout(const Duration(seconds: 20));
    final row = (result as Map).cast<String, dynamic>();
    return (row['balance'] as num?)?.toDouble() ?? 0;
  }

  Future<String> recordAdjustment({
    required String userId,
    required double amount,
    required String method,
    required String note,
    String? reversedPaymentId,
    String? idempotencyKey,
  }) async {
    final result = await _client
        .rpc(
          'admin_record_payment_adjustment',
          params: {
            'p_user_id': userId,
            'p_amount': amount,
            'p_method': method,
            'p_note': note,
            'p_reversed_payment_id': reversedPaymentId,
            'p_idempotency_key': idempotencyKey ?? operationKey('adjustment'),
          },
        )
        .timeout(const Duration(seconds: 20));
    return result.toString();
  }

  Future<void> cancelPackage(String id) => _client
      .rpc('admin_cancel_client_package', params: {'p_package_id': id})
      .timeout(const Duration(seconds: 20));

  Future<void> cancelMembership(String id) => _client
      .rpc('admin_cancel_client_membership', params: {'p_membership_id': id})
      .timeout(const Duration(seconds: 20));

  Future<void> setArchived(String userId, bool archived) => _client
      .rpc(
        'admin_set_client_archived',
        params: {'p_user_id': userId, 'p_archived': archived},
      )
      .timeout(const Duration(seconds: 20));

  Future<Map<String, dynamic>> resetClientData(String userId) async {
    final result = await _client
        .rpc('admin_reset_client_data', params: {'p_user_id': userId})
        .timeout(const Duration(seconds: 30));
    return (result as Map).cast<String, dynamic>();
  }

  static String operationKey(String prefix) =>
      'flutter:$prefix:${DateTime.now().microsecondsSinceEpoch}';
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString());

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final clientOperationsRepositoryProvider = Provider<ClientOperationsRepository>(
  (ref) => ClientOperationsRepository(ref.watch(supabaseProvider)),
);

final clientFinancialSummaryProvider = FutureProvider.autoDispose
    .family<ClientFinancialSummary, String>((ref, userId) async {
      return ref.watch(clientOperationsRepositoryProvider).fetchSummary(userId);
    });
