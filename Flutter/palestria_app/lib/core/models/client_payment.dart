/// Riga del ledger `payments` visibile al CLIENTE (RLS: client_user_id =
/// auth.uid()). È lo storico delle sue transazioni: lezioni, abbonamenti,
/// pacchetti, more/rettifiche. Fonte unica del "fatturato" anche lato admin.
class ClientPayment {
  const ClientPayment({
    required this.id,
    required this.amount,
    required this.currency,
    required this.method,
    required this.kind,
    this.createdAt,
    this.note,
    this.periodStart,
    this.periodEnd,
  });

  final String id;
  final double amount;
  final String currency;

  /// contanti | contanti-report | carta | iban | stripe | gratuito
  final String method;

  /// session | membership | package_purchase | penalty_mora | adjustment
  final String kind;

  final DateTime? createdAt;
  final String? note;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  static ClientPayment fromRow(Map<String, dynamic> row) => ClientPayment(
    id: row['id'] as String,
    amount: (row['amount'] as num?)?.toDouble() ?? 0,
    currency: (row['currency'] as String?) ?? 'EUR',
    method: (row['method'] as String?) ?? '',
    kind: (row['kind'] as String?) ?? '',
    createdAt: _date(row['created_at']),
    note: row['note'] as String?,
    periodStart: _date(row['period_start']),
    periodEnd: _date(row['period_end']),
  );

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  static const selectColumns =
      'id, amount, currency, method, kind, created_at, note, '
      'period_start, period_end';
}
