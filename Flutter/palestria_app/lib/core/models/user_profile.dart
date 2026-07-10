/// Profilo cliente (tabella `profiles`) — colonne caricate da _loadProfile
/// nella web app (spec-data §2.3).
class UserProfile {
  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    this.whatsapp,
    this.medicalCertExpiry,
    this.insuranceExpiry,
    this.codiceFiscale,
    this.indirizzoVia,
    this.indirizzoPaese,
    this.indirizzoCap,
    this.documentoFirmato = false,
    this.privacyPrenotazioni = true,
    this.createdAt,
  });

  final String id;
  final String name;
  final String email;
  final String? whatsapp;
  final DateTime? medicalCertExpiry;
  final DateTime? insuranceExpiry;
  final String? codiceFiscale;
  final String? indirizzoVia;
  final String? indirizzoPaese;
  final String? indirizzoCap;
  final bool documentoFirmato;

  /// true → il cliente compare come "Anonimo" nelle liste iscritti.
  final bool privacyPrenotazioni;
  final DateTime? createdAt;

  static UserProfile fromRow(Map<String, dynamic> row) => UserProfile(
    id: row['id'] as String,
    name: (row['name'] as String?) ?? '',
    email: (row['email'] as String?) ?? '',
    whatsapp: row['whatsapp'] as String?,
    medicalCertExpiry: _date(row['medical_cert_expiry']),
    insuranceExpiry: _date(row['insurance_expiry']),
    codiceFiscale: row['codice_fiscale'] as String?,
    indirizzoVia: row['indirizzo_via'] as String?,
    indirizzoPaese: row['indirizzo_paese'] as String?,
    indirizzoCap: row['indirizzo_cap'] as String?,
    documentoFirmato: (row['documento_firmato'] as bool?) ?? false,
    privacyPrenotazioni: (row['privacy_prenotazioni'] as bool?) ?? true,
    createdAt: _date(row['created_at']),
  );

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  static const selectColumns =
      'id, name, email, whatsapp, medical_cert_expiry, insurance_expiry, '
      'codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap, '
      'documento_firmato, privacy_prenotazioni, created_at';
}
