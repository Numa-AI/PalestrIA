/// Contratto condiviso dei modelli di pagamento cliente.
///
/// Nel database le tre durate ricorrenti usano ancora `default_model=monthly`
/// per compatibilita con il motore prenotazioni; la periodicita esplicita vive
/// in `default_membership_period`.
const clientBillingModels = <(String, String, String)>[
  ('pay_per_session', 'A entrata', 'Ogni lezione ha il prezzo del suo slot.'),
  ('package', 'Pacchetto', 'Carnet di ingressi prepagato.'),
  (
    'monthly',
    'Abbonamento',
    'Listino con pacchetti da 1, 3 oppure 12 mesi.',
  ),
  ('free', 'Gratuito', 'Nessun pagamento richiesto.'),
];

bool isMembershipBillingModel(String model) =>
    model == 'monthly' || model == 'quarterly' || model == 'annual';

String effectiveBillingModel(
  Map<String, dynamic>? settings, [
  Map<String, dynamic>? clientProfile,
]) {
  final base =
      clientProfile?['model_override'] as String? ??
      settings?['default_model'] as String? ??
      'pay_per_session';
  return base;
}

int billingPeriodMonths(String period) => switch (period) {
  'quarterly' => 3,
  'annual' => 12,
  _ => 1,
};

String billingPeriodLabel(String period) => switch (period) {
  'quarterly' => 'trimestrale',
  'annual' => 'annuale',
  _ => 'mensile',
};

String billingPeriodPriceColumn(String period) => switch (period) {
  'quarterly' => 'membership_quarterly_price',
  'annual' => 'membership_annual_price',
  _ => 'membership_monthly_price',
};

DateTime membershipPeriodEnd(DateTime start, String period) =>
    DateTime(start.year, start.month + billingPeriodMonths(period), start.day);
