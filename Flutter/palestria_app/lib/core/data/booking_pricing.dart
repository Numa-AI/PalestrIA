import '../models/booking.dart';
import '../org/org_settings_service.dart';
import 'schedule_config.dart';

/// Email degli admin/piattaforma escluse dalle statistiche (come `ADMIN_EMAILS`
/// di js/data.js). Nel modello multi-tenant non matchano gli altri tenant, quindi
/// escluderle è innocuo e mantiene la parità col web per la org di riferimento.
const adminStatsEmails = <String>{
  'demo@palestria.app',
  'andrea.pompili1997@gmail.com',
};

bool isAdminStatsEmail(String? email) =>
    email != null && adminStatsEmails.contains(email.toLowerCase());

/// Prezzo di una prenotazione — port 1:1 di `getBookingPrice()` (js/data.js §181).
/// Ordine: 1) `custom_price`, 2) `billing_client.prices[slotType]` (listino
/// cliente per-org), 3) `price.<slotType>` (OrgSettings legacy),
/// 4) `slot_types.default_price` (equivalente per-org di SLOT_PRICES), 5) 0.
double bookingPrice(
  Booking b,
  OrgSettingsService? settings,
  OrgScheduleConfig? config,
) {
  final custom = b.customPrice;
  if (custom != null && !custom.isNaN) return custom;

  if (settings != null && b.slotType.isNotEmpty) {
    final prices = (settings.get('billing_client.prices') as Map?)
        ?.cast<String, dynamic>();
    final p = (prices?[b.slotType] as num?)?.toDouble();
    if (p != null && p.isFinite) return p;

    final legacy = settings.getNumber('price.${b.slotType}', double.nan);
    if (legacy.isFinite) return legacy.toDouble();
  }

  final st = config?.slotTypes[b.slotType];
  if (st != null) return st.defaultPrice;
  return 0;
}
