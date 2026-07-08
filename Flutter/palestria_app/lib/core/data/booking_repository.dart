import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_providers.dart';
import '../models/booking.dart';
import 'schedule_config.dart';

/// Esito di una scrittura booking, con messaggi già in italiano.
class BookingResult {
  const BookingResult.ok({this.bookingId, this.paid = false})
      : ok = true,
        error = null,
        errorCode = null;
  const BookingResult.fail(this.errorCode, this.error)
      : ok = false,
        bookingId = null,
        paid = false;

  final bool ok;
  final String? bookingId;
  final bool paid;
  final String? errorCode;
  final String? error;
}

/// Repository prenotazioni lato CLIENTE (port del percorso "utente
/// autenticato" di BookingStorage, spec-data §5.3). Il server è SEMPRE
/// l'autorità su capienze e regole: qui solo RPC + cache di lettura.
class BookingRepository {
  BookingRepository(this._client, {required this.orgSlug});

  final SupabaseClient _client;

  /// Slug della org (per le RPC pubbliche); '' → il server usa current_org_id().
  final String orgSlug;

  // Cache disponibilità: chiave 'from|to', TTL 60 s (come _availCache web).
  final Map<String, (DateTime, List<SlotAvailability>)> _availCache = {};

  /// Prenotazioni dell'utente corrente, finestrate come il web:
  /// date ≤ oggi+90 e (date ≥ oggi−60 oppure non pagata non annullata).
  Future<List<Booking>> fetchOwnBookings(String userId) async {
    final today = DateTime.now();
    final from =
        OrgScheduleConfig.localDateStr(today.subtract(const Duration(days: 60)));
    final to =
        OrgScheduleConfig.localDateStr(today.add(const Duration(days: 90)));
    final rows = await _client
        .from('bookings')
        .select(Booking.selectColumns)
        .eq('user_id', userId)
        .lte('date', to)
        .or('date.gte.$from,and(paid.eq.false,status.neq.cancelled)')
        .order('date')
        .order('time')
        .timeout(const Duration(seconds: 12));
    return [for (final r in rows) Booking.fromRow(r)];
  }

  /// Disponibilità aggregata server-authoritative (solo slot con ≥1 occupato;
  /// gli slot liberi si deducono dalla config orari locale).
  Future<List<SlotAvailability>> fetchAvailability(
      DateTime from, DateTime to) async {
    final fromStr = OrgScheduleConfig.localDateStr(from);
    final toStr = OrgScheduleConfig.localDateStr(to);
    final cacheKey = '$fromStr|$toStr';

    final cached = _availCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(seconds: 60)) {
      return cached.$2;
    }

    final result = await _client.rpc('get_availability_range', params: {
      'p_org_slug': orgSlug,
      'p_from': fromStr,
      'p_to': toStr,
    }).timeout(const Duration(seconds: 12));

    final list = [
      for (final item in (result as List? ?? const []))
        SlotAvailability.fromJson(item as Map<String, dynamic>)
    ];
    _availCache[cacheKey] = (DateTime.now(), list);
    return list;
  }

  void invalidateAvailability() => _availCache.clear();

  /// Iscritti a uno slot, raggruppabili per tipo (RPC get_slot_attendees).
  Future<List<SlotAttendee>> slotAttendees(String date, String time) async {
    final rows = await _client.rpc('get_slot_attendees', params: {
      'p_org_slug': orgSlug,
      'p_date': date,
      'p_time': time,
    }).timeout(const Duration(seconds: 12));
    return [
      for (final r in (rows as List? ?? const []))
        SlotAttendee(
          name: (r['name'] as String?) ?? 'Anonimo',
          slotType: (r['slot_type'] as String?) ?? '',
        )
    ];
  }

  /// Prenota via RPC `book_slot` (server-authoritative: advisory lock,
  /// capienza, cutoff, gating billing). Timeout 45 s come il web.
  Future<BookingResult> book({
    required String date,
    required String time,
    required String name,
    required String email,
    String? whatsapp,
    String? notes,
    String dateDisplay = '',
  }) async {
    final localId =
        '${DateTime.now().millisecondsSinceEpoch}-${_rand36(9)}';
    try {
      final res = await _client.rpc('book_slot', params: {
        'p_org_slug': orgSlug,
        'p_local_id': localId,
        'p_date': date,
        'p_time': time,
        'p_name': name,
        'p_email': email,
        'p_whatsapp': whatsapp ?? '',
        'p_notes': notes ?? '',
        'p_date_display': dateDisplay,
      }).timeout(const Duration(seconds: 45));

      final map = (res as Map).cast<String, dynamic>();
      invalidateAvailability();
      if (map['success'] == true) {
        return BookingResult.ok(
          bookingId: map['booking_id'] as String?,
          paid: (map['paid'] as bool?) ?? false,
        );
      }
      final code = (map['error'] as String?) ?? 'server_error';
      return BookingResult.fail(code, bookSlotErrorMessage(code));
    } on TimeoutException {
      // Il server POTREBBE aver committato la prenotazione: non dire "non
      // salvata" e invalida la cache disponibilità, così il retry non
      // porta a un doppione e la lista si riallinea.
      invalidateAvailability();
      return const BookingResult.fail(
          'timeout',
          'Connessione lenta: non è chiaro se la prenotazione sia stata registrata. '
              'Controlla "Le mie prenotazioni" prima di riprovare.');
    } catch (_) {
      invalidateAvailability();
      return const BookingResult.fail(
          'offline', 'Errore di connessione: prenotazione non salvata.');
    }
  }

  /// Annulla via RPC `cancel_booking` (cutoff/refund lato server).
  Future<BookingResult> cancelBooking(String bookingId) async {
    try {
      final res = await _client.rpc('cancel_booking',
          params: {'p_booking_id': bookingId}).timeout(
          const Duration(seconds: 12));
      final map = (res as Map).cast<String, dynamic>();
      invalidateAvailability();
      if (map['success'] == true) return const BookingResult.ok();
      final code = (map['error'] as String?) ?? 'server_error';
      return BookingResult.fail(code, cancelErrorMessage(code));
    } catch (_) {
      return BookingResult.fail('offline', 'Errore di connessione. Riprova.');
    }
  }

  /// Richiesta di cancellazione (fuori finestra) via
  /// `user_request_cancellation`.
  Future<BookingResult> requestCancellation(String bookingId) async {
    try {
      final res = await _client.rpc('user_request_cancellation',
          params: {'p_booking_id': bookingId}).timeout(
          const Duration(seconds: 12));
      final map = (res as Map).cast<String, dynamic>();
      if (map['success'] == true) return const BookingResult.ok();
      final code = (map['error'] as String?) ?? 'server_error';
      return BookingResult.fail(code, cancelErrorMessage(code));
    } catch (_) {
      return BookingResult.fail('offline', 'Errore di connessione. Riprova.');
    }
  }

  static String _rand36(int len) {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final rnd = Random();
    return List.generate(len, (_) => chars[rnd.nextInt(36)]).join();
  }

  /// Messaggi utente per i codici errore di book_slot (spec-data §4.2).
  static String bookSlotErrorMessage(String code) => switch (code) {
        'slot_full' => 'Lo slot è al completo.',
        'slot_busy' =>
          'Qualcun altro sta prenotando questo slot: riprova tra un attimo.',
        'too_late' =>
          'Prenotazione non più possibile: la lezione è già iniziata da oltre 30 minuti.',
        'past_date' => 'Non puoi prenotare una data passata.',
        'not_bookable' => 'Questo slot non è prenotabile.',
        'no_package' =>
          'Nessun pacchetto attivo: contatta il tuo trainer per acquistarne uno.',
        'membership_expired' =>
          'Abbonamento scaduto: contatta il tuo trainer per rinnovarlo.',
        'quota_exceeded' =>
          'Hai esaurito le lezioni del tuo abbonamento per questo periodo.',
        'duplicate_booking' => 'Hai già una prenotazione per questo slot.',
        'invalid_email' => 'Email non valida.',
        'missing_name' => 'Inserisci il nome.',
        'org_not_found' => 'Studio non trovato.',
        _ => 'Errore del server. Riprova.',
      };

  static String cancelErrorMessage(String code) => switch (code) {
        'cancellation_window_closed' =>
          'Finestra di cancellazione chiusa: puoi solo richiedere l\'annullo al trainer.',
        'already_cancelled' => 'Prenotazione già annullata.',
        'not_confirmed' => 'La prenotazione non è in stato confermato.',
        'booking_not_found' => 'Prenotazione non trovata.',
        'unauthorized' => 'Operazione non consentita.',
        _ => 'Errore del server. Riprova.',
      };
}

/// Slug della org corrente (serve alle RPC pubbliche). Cache in-memory.
final orgSlugProvider = FutureProvider<String>((ref) async {
  final orgContext = await ref.watch(orgContextProvider.future);
  final orgId = orgContext.orgId;
  if (orgId == null) return '';
  final row = await ref
      .read(supabaseProvider)
      .from('organizations')
      .select('slug')
      .eq('id', orgId)
      .maybeSingle();
  return (row?['slug'] as String?) ?? '';
});

final bookingRepositoryProvider = FutureProvider<BookingRepository>((ref) async {
  final slug = await ref.watch(orgSlugProvider.future);
  return BookingRepository(ref.watch(supabaseProvider), orgSlug: slug);
});
