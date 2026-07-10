/// Prenotazione (tabella `bookings`), mappata come `_mapRow` del web
/// (spec-data §5.3): `id` = local_id se presente, `sbId` = uuid del DB.
class Booking {
  const Booking({
    required this.id,
    this.sbId,
    this.userId,
    required this.date,
    required this.time,
    required this.slotType,
    this.dateDisplay,
    this.name,
    this.email,
    this.whatsapp,
    this.notes,
    this.status = 'confirmed',
    this.paid = false,
    this.paymentMethod,
    this.paidAt,
    this.customPrice,
    this.billingVoidedAt,
    this.billingVoidReason,
    this.createdAt,
    this.cancellationRequestedAt,
    this.cancelledAt,
    this.updatedAt,
    this.arrivedAt,
    this.synthetic = false,
  });

  final String id;
  final String? sbId;
  final String? userId;

  /// `YYYY-MM-DD`
  final String date;

  /// `"HH:MM - HH:MM"`
  final String time;
  final String slotType;
  final String? dateDisplay;
  final String? name;
  final String? email;
  final String? whatsapp;
  final String? notes;

  /// confirmed | cancellation_requested | cancelled
  final String status;
  final bool paid;
  final String? paymentMethod;
  final DateTime? paidAt;
  final double? customPrice;
  final DateTime? billingVoidedAt;
  final String? billingVoidReason;
  final DateTime? createdAt;
  final DateTime? cancellationRequestedAt;
  final DateTime? cancelledAt;
  final DateTime? updatedAt;
  final DateTime? arrivedAt;

  /// true per i booking sintetici creati dalla disponibilità server
  /// (posti occupati da altri, senza dati personali).
  final bool synthetic;

  bool get isOccupying =>
      status == 'confirmed' || status == 'cancellation_requested';
  bool get isBillingVoided => billingVoidedAt != null;

  static Booking fromRow(Map<String, dynamic> row) => Booking(
    id: (row['local_id'] as String?) ?? (row['id'] as String),
    sbId: row['id'] as String?,
    userId: row['user_id'] as String?,
    date: row['date'] as String,
    time: row['time'] as String,
    slotType: (row['slot_type'] as String?) ?? '',
    dateDisplay: row['date_display'] as String?,
    name: row['name'] as String?,
    email: row['email'] as String?,
    whatsapp: row['whatsapp'] as String?,
    notes: row['notes'] as String?,
    status: (row['status'] as String?) ?? 'confirmed',
    paid: (row['paid'] as bool?) ?? false,
    paymentMethod: row['payment_method'] as String?,
    paidAt: _ts(row['paid_at']),
    customPrice: (row['custom_price'] as num?)?.toDouble(),
    billingVoidedAt: _ts(row['billing_voided_at']),
    billingVoidReason: row['billing_void_reason'] as String?,
    createdAt: _ts(row['created_at']),
    cancellationRequestedAt: _ts(row['cancellation_requested_at']),
    cancelledAt: _ts(row['cancelled_at']),
    updatedAt: _ts(row['updated_at']),
    arrivedAt: _ts(row['arrived_at']),
  );

  static DateTime? _ts(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString());

  /// Colonne selezionate dal client (stessa lista del web).
  static const selectColumns =
      'id, local_id, user_id, date, time, slot_type, date_display, name, '
      'email, whatsapp, notes, status, paid, payment_method, paid_at, '
      'custom_price, billing_voided_at, billing_void_reason, created_at, '
      'cancellation_requested_at, cancelled_at, '
      'updated_at, arrived_at';
}

/// Riga di `get_availability_range` / `get_slot_availability`:
/// capienza server-authoritative per slot con almeno un posto occupato.
class SlotAvailability {
  const SlotAvailability({
    required this.date,
    required this.time,
    required this.slotType,
    required this.capacity,
    required this.confirmedCount,
    required this.remaining,
  });

  final String date;
  final String time;
  final String slotType;
  final int capacity;

  /// ⚠️ conta gli OCCUPATI (confirmed + cancellation_requested),
  /// il nome è per retro-compatibilità.
  final int confirmedCount;
  final int remaining;

  String get key => '$date|$time|$slotType';

  static SlotAvailability fromJson(Map<String, dynamic> json, {String? date}) =>
      SlotAvailability(
        date: date ?? (json['date'] as String? ?? ''),
        time: json['time'] as String,
        slotType: (json['slot_type'] as String?) ?? '',
        capacity: (json['capacity'] as num?)?.toInt() ?? 0,
        confirmedCount: (json['confirmed_count'] as num?)?.toInt() ?? 0,
        remaining: (json['remaining'] as num?)?.toInt() ?? 0,
      );
}

/// Iscritto a uno slot (RPC `get_slot_attendees`, firma post mig. 0027).
class SlotAttendee {
  const SlotAttendee({required this.name, required this.slotType});

  /// 'Anonimo' se il cliente ha privacy_prenotazioni=true.
  final String name;
  final String slotType;
}
