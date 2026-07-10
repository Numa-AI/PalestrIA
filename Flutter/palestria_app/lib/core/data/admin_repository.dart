import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../auth/normalize.dart';
import '../models/booking.dart';

/// Profilo cliente lato admin (da get_all_profiles_basic, spec-data §4.4).
class AdminProfile {
  const AdminProfile({
    required this.id,
    required this.name,
    required this.email,
    this.whatsapp,
    this.medicalCertExpiry,
    this.insuranceExpiry,
    this.codiceFiscale,
    this.indirizzoVia,
    this.indirizzoCap,
    this.indirizzoPaese,
    this.documentoFirmato = false,
    this.privacyPrenotazioni = true,
    this.pushEnabled = false,
    this.archivedAt,
  });

  final String id;
  final String name;
  final String email;
  final String? whatsapp;
  final DateTime? medicalCertExpiry;
  final DateTime? insuranceExpiry;
  final String? codiceFiscale;
  final String? indirizzoVia;
  final String? indirizzoCap;
  final String? indirizzoPaese;
  final bool documentoFirmato;
  final bool privacyPrenotazioni;
  final bool pushEnabled;
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  bool get anagraficaIncompleta => !isAnagraficaComplete(
    whatsapp: whatsapp,
    codiceFiscale: codiceFiscale,
    indirizzoVia: indirizzoVia,
    indirizzoPaese: indirizzoPaese,
    indirizzoCap: indirizzoCap,
  );

  static AdminProfile fromRow(Map<String, dynamic> row) => AdminProfile(
    id: row['id'] as String,
    name: (row['name'] as String?) ?? '',
    email: (row['email'] as String?) ?? '',
    whatsapp: row['whatsapp'] as String?,
    medicalCertExpiry: _date(row['medical_cert_expiry']),
    insuranceExpiry: _date(row['insurance_expiry']),
    codiceFiscale: row['codice_fiscale'] as String?,
    indirizzoVia: row['indirizzo_via'] as String?,
    indirizzoCap: row['indirizzo_cap'] as String?,
    indirizzoPaese: row['indirizzo_paese'] as String?,
    documentoFirmato: (row['documento_firmato'] as bool?) ?? false,
    privacyPrenotazioni: (row['privacy_prenotazioni'] as bool?) ?? true,
    pushEnabled: (row['push_enabled'] as bool?) ?? false,
    archivedAt: _date(row['archived_at']),
  );

  static DateTime? _date(Object? v) => (v == null || v.toString().isEmpty)
      ? null
      : DateTime.tryParse(v.toString());
}

/// Cliente aggregato (profilo + sue prenotazioni), come getAllClients() web.
class AdminClient {
  AdminClient({
    this.userId,
    required this.name,
    this.whatsapp,
    this.email,
    required this.bookings,
    this.profile,
  });

  final String? userId;
  final String name;
  final String? whatsapp;
  final String? email;
  final List<Booking> bookings;
  final AdminProfile? profile;

  /// Attivo: ≥1 prenotazione non cancellata tra 2 mesi fa e 1 mese avanti.
  bool get isActive {
    if (profile?.isArchived == true) return false;
    final now = DateTime.now();
    final from = DateTime(now.year, now.month - 2, now.day);
    final to = DateTime(now.year, now.month + 1, now.day);
    return bookings.any((b) {
      if (b.status == 'cancelled') return false;
      final d = DateTime.tryParse(b.date);
      return d != null && !d.isBefore(from) && !d.isAfter(to);
    });
  }
}

class AdminRepository {
  AdminRepository(this._client, this.orgId);

  final SupabaseClient _client;
  final String orgId;

  /// Prenotazioni org finestrate (60gg passate + 90 future + debiti vecchi),
  /// come la finestra FULL admin di BookingStorage (spec-data §5.3).
  Future<List<Booking>> fetchAllBookings() async {
    final now = DateTime.now();
    String ymd(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final from = ymd(now.subtract(const Duration(days: 60)));
    final to = ymd(now.add(const Duration(days: 90)));

    final all = <Booking>[];
    var offset = 0;
    const batch = 1000;
    while (true) {
      final rows = await _client
          .from('bookings')
          .select(Booking.selectColumns)
          .eq('org_id', orgId)
          .lte('date', to)
          .or('date.gte.$from,and(paid.eq.false,status.neq.cancelled)')
          .order('date', ascending: false)
          .order('id')
          .range(offset, offset + batch - 1)
          .timeout(const Duration(seconds: 15));
      all.addAll([for (final r in rows) Booking.fromRow(r)]);
      if (rows.length < batch) break;
      offset += batch;
    }
    return all;
  }

  /// Prenotazioni org su finestra ampia (per l'analytics con filtri
  /// mese/anno/anno scorso). Il web estende il range a ±12 mesi attorno al
  /// filtro; qui fetchiamo generosamente 24 mesi indietro → 12 avanti così da
  /// coprire "quest'anno"/"anno scorso" e i relativi periodi di confronto.
  Future<List<Booking>> fetchBookingsRange(String fromYmd, String toYmd) async {
    final all = <Booking>[];
    var offset = 0;
    const batch = 1000;
    while (true) {
      final rows = await _client
          .from('bookings')
          .select(Booking.selectColumns)
          .eq('org_id', orgId)
          .gte('date', fromYmd)
          .lte('date', toYmd)
          .order('date', ascending: false)
          .order('id')
          .range(offset, offset + batch - 1)
          .timeout(const Duration(seconds: 15));
      all.addAll([for (final r in rows) Booking.fromRow(r)]);
      if (rows.length < batch) break;
      offset += batch;
    }
    return all;
  }

  /// Tutti i profili della org (RPC get_all_profiles_basic con fallback).
  Future<List<AdminProfile>> fetchProfiles() async {
    try {
      final rows = await _client
          .rpc('get_all_profiles_basic')
          .timeout(const Duration(seconds: 15));
      return [for (final r in (rows as List)) AdminProfile.fromRow(r)];
    } catch (_) {
      final rows = await _client
          .rpc('get_all_profiles')
          .timeout(const Duration(seconds: 15));
      return [for (final r in (rows as List)) AdminProfile.fromRow(r)];
    }
  }

  /// Registra i pagamenti via RPC admin_pay_bookings (ledger payments).
  Future<int> payBookings(List<String> bookingIds, String method) async {
    final res = await _client
        .rpc(
          'admin_pay_bookings',
          params: {'p_booking_ids': bookingIds, 'p_method': method},
        )
        .timeout(const Duration(seconds: 30));
    return (res as num?)?.toInt() ?? 0;
  }

  /// Righe del ledger payments (per il fatturato reale e i pagamenti recenti).
  Future<List<PaymentRow>> fetchPayments({DateTime? since}) async {
    var query = _client
        .from('payments')
        .select(
          'id, amount, kind, method, client_email, created_at, note, period_start, period_end',
        )
        .eq('org_id', orgId);
    if (since != null) {
      query = query.gte('created_at', since.toIso8601String());
    }
    final rows = await query
        .order('created_at', ascending: false)
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) PaymentRow.fromRow(r)];
  }

  Future<void> deleteBooking(String bookingId) async {
    await _client
        .rpc('admin_delete_booking', params: {'p_booking_id': bookingId})
        .timeout(const Duration(seconds: 15));
  }

  /// Annulla una prenotazione (RPC cancel_booking: cancelled + conversione
  /// group-class→small-group lato server).
  Future<void> cancelBooking(String bookingId) async {
    await _client
        .rpc('cancel_booking', params: {'p_booking_id': bookingId})
        .timeout(const Duration(seconds: 15));
  }

  /// Prenota per conto di un cliente (RPC book_slot con p_for_user_id).
  /// Ritorna null se ok, altrimenti il codice errore.
  Future<String?> bookForClient({
    required String orgSlug,
    required String date,
    required String time,
    required String name,
    required String email,
    String? whatsapp,
    String dateDisplay = '',
    String? forUserId,
  }) async {
    final localId = '${DateTime.now().millisecondsSinceEpoch}-${_rand36(9)}';
    try {
      final res = await _client
          .rpc(
            'book_slot',
            params: {
              'p_org_slug': orgSlug,
              'p_local_id': localId,
              'p_date': date,
              'p_time': time,
              'p_name': name,
              'p_email': email,
              'p_whatsapp': whatsapp ?? '',
              'p_notes': '',
              'p_date_display': dateDisplay,
              'p_for_user_id': forUserId,
            },
          )
          .timeout(const Duration(seconds: 45));
      final map = (res as Map).cast<String, dynamic>();
      if (map['success'] == true) return null;
      return (map['error'] as String?) ?? 'server_error';
    } catch (_) {
      return 'offline';
    }
  }

  /// Invia un messaggio push ai clienti (edge send-admin-message).
  /// mode ∈ tutti | giorno | ora. Ritorna il numero di invii, o lancia.
  Future<int> sendMessage({
    required String title,
    required String body,
    required String mode,
    String? date,
    String? time,
  }) async {
    final res = await _client.functions.invoke(
      'send-admin-message',
      body: {
        'title': title,
        'body': body,
        'mode': mode,
        'date': ?date,
        'time': ?time,
      },
    );
    final data = (res.data as Map?)?.cast<String, dynamic>();
    if (data?['ok'] == true) return (data?['sent'] as num?)?.toInt() ?? 0;
    throw Exception(data?['error'] ?? 'Invio non riuscito');
  }

  /// Storico notifiche admin (tabella admin_messages).
  Future<List<Map<String, dynamic>>> fetchAdminMessages() async {
    final rows = await _client
        .from('admin_messages')
        .select('created_at, type, date, title, body, client_name, sent_count')
        .eq('org_id', orgId)
        .order('created_at', ascending: false)
        .limit(300)
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  /// Notifiche ai clienti (tabella client_notifications).
  Future<List<Map<String, dynamic>>> fetchClientNotifications() async {
    final rows = await _client
        .from('client_notifications')
        .select(
          'created_at, type, status, user_name, user_email, title, body, error, booking_date',
        )
        .eq('org_id', orgId)
        .order('created_at', ascending: false)
        .limit(300)
        .timeout(const Duration(seconds: 15));
    return [for (final r in rows) (r as Map).cast<String, dynamic>()];
  }

  static String _rand36(int len) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    var seed = DateTime.now().microsecondsSinceEpoch;
    final buf = StringBuffer();
    for (var i = 0; i < len; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      buf.write(chars[seed % 36]);
    }
    return buf.toString();
  }
}

/// Riga del ledger payments (spec-admin §7.13).
class PaymentRow {
  const PaymentRow({
    required this.id,
    required this.amount,
    required this.kind,
    required this.method,
    this.clientEmail,
    this.createdAt,
    this.note,
    this.periodStart,
    this.periodEnd,
  });

  final String id;
  final double amount;

  /// session | membership | package_purchase | penalty_mora | adjustment | account_credit
  final String kind;

  /// contanti | contanti-report | carta | iban | stripe | gratuito
  final String method;
  final String? clientEmail;
  final DateTime? createdAt;
  final String? note;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  static PaymentRow fromRow(Map<String, dynamic> row) => PaymentRow(
    id: row['id'] as String,
    amount: (row['amount'] as num?)?.toDouble() ?? 0,
    kind: (row['kind'] as String?) ?? 'session',
    method: (row['method'] as String?) ?? 'contanti',
    clientEmail: row['client_email'] as String?,
    createdAt: _date(row['created_at']),
    note: row['note'] as String?,
    periodStart: _date(row['period_start']),
    periodEnd: _date(row['period_end']),
  );

  static const kindLabels = {
    'session': 'Lezione',
    'membership': 'Abbonamento',
    'package_purchase': 'Pacchetto',
    'penalty_mora': 'Mora',
    'adjustment': 'Rettifica',
    'account_credit': 'Versamento credito',
  };

  static const methodLabels = {
    'contanti': '💵 Contanti',
    'contanti-report': '🧾 Contanti con Report',
    'carta': '💳 Carta',
    'iban': '🏦 Bonifico',
    'stripe': '🌐 Stripe',
    'gratuito': '🎁 Gratuito',
  };

  static DateTime? _date(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());
}

final adminRepositoryProvider = FutureProvider<AdminRepository?>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  if (orgContext.orgId == null || !orgContext.isOrgAdmin) return null;
  return AdminRepository(ref.watch(supabaseProvider), orgContext.orgId!);
});

/// Prenotazioni org (refresh: ref.invalidate).
final adminBookingsProvider = FutureProvider<List<Booking>>((ref) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  return repo.fetchAllBookings();
});

/// Prenotazioni org su finestra ampia per l'analytics (24 mesi indietro →
/// 12 avanti), così i filtri anno/mese e i confronti col periodo precedente
/// hanno dati sufficienti. Separato da [adminBookingsProvider] (che è
/// finestrato 60/90gg per le tab operative) per non allargarne l'egress.
final statsBookingsProvider = FutureProvider<List<Booking>>((ref) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  final now = DateTime.now();
  String ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final from = ymd(DateTime(now.year - 2, now.month, 1));
  final to = ymd(DateTime(now.year + 1, now.month + 1, 0));
  return repo.fetchBookingsRange(from, to);
});

/// Profili org.
final adminProfilesProvider = FutureProvider<List<AdminProfile>>((ref) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  return repo.fetchProfiles();
});

/// Clienti aggregati da prenotazioni + profili (getAllClients()).
final adminClientsProvider = FutureProvider<List<AdminClient>>((ref) async {
  final bookings = await ref.watch(adminBookingsProvider.future);
  final profiles = await ref.watch(adminProfilesProvider.future);

  final byPhone = <String, AdminClient>{};
  final byEmail = <String, AdminClient>{};
  final clients = <AdminClient>[];

  String? phoneKey(String? w) {
    if (w == null || w.trim().isEmpty) return null;
    final n = normalizePhone(w);
    final digits = n.replaceAll(RegExp(r'\D'), '');
    return digits.length >= 10 ? digits.substring(digits.length - 10) : digits;
  }

  AdminClient findOrCreate(String name, String? email, String? whatsapp) {
    final ek = email?.toLowerCase();
    final pk = phoneKey(whatsapp);
    if (ek != null && byEmail.containsKey(ek)) return byEmail[ek]!;
    if (pk != null && byPhone.containsKey(pk)) return byPhone[pk]!;
    final c = AdminClient(
      name: name,
      email: email,
      whatsapp: whatsapp,
      bookings: [],
    );
    clients.add(c);
    if (ek != null) byEmail[ek] = c;
    if (pk != null) byPhone[pk] = c;
    return c;
  }

  for (final b in bookings) {
    final c = findOrCreate(b.name ?? '', b.email, b.whatsapp);
    c.bookings.add(b);
  }

  // Integra i profili registrati (anche senza prenotazioni).
  final result = <AdminClient>[];
  final consumed = <AdminClient>{};
  for (final p in profiles) {
    final ek = p.email.toLowerCase();
    final pk = phoneKey(p.whatsapp);
    AdminClient? existing;
    if (byEmail.containsKey(ek)) {
      existing = byEmail[ek];
    } else if (pk != null && byPhone.containsKey(pk)) {
      existing = byPhone[pk];
    }
    if (existing != null) {
      consumed.add(existing);
      result.add(
        AdminClient(
          userId: p.id,
          name: existing.name.isNotEmpty ? existing.name : p.name,
          email: p.email,
          whatsapp: p.whatsapp ?? existing.whatsapp,
          bookings: existing.bookings
            ..sort(
              (a, b) => '${b.date}${b.time}'.compareTo('${a.date}${a.time}'),
            ),
          profile: p,
        ),
      );
    } else {
      result.add(
        AdminClient(
          userId: p.id,
          name: p.name,
          email: p.email,
          whatsapp: p.whatsapp,
          bookings: [],
          profile: p,
        ),
      );
    }
  }
  // Clienti solo da prenotazioni (senza profilo).
  for (final c in clients) {
    if (!consumed.contains(c)) {
      c.bookings.sort(
        (a, b) => '${b.date}${b.time}'.compareTo('${a.date}${a.time}'),
      );
      result.add(c);
    }
  }

  result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return result;
});

/// Pagamenti del mese corrente (per "Incassato questo mese" + recenti).
final monthPaymentsProvider = FutureProvider<List<PaymentRow>>((ref) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  final now = DateTime.now();
  return repo.fetchPayments(since: DateTime(now.year, now.month));
});

/// Pagamenti da inizio anno scorso (per l'analytics con filtro periodo).
final statsPaymentsProvider = FutureProvider<List<PaymentRow>>((ref) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  final now = DateTime.now();
  return repo.fetchPayments(since: DateTime(now.year - 1, 1, 1));
});

final adminMessagesProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  return repo.fetchAdminMessages();
});

final clientNotificationsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final repo = await ref.watch(adminRepositoryProvider.future);
  if (repo == null) return const [];
  return repo.fetchClientNotifications();
});
