-- ─── CONSTRAINTS: integrità dati ─────────────────────────────────────────────

-- status: solo valori ammessi dal dominio applicativo
alter table bookings
    add constraint bookings_status_check
    check (status in ('confirmed', 'cancellation_requested', 'cancelled'));

-- slot_type: solo i tre tipi di lezione esistenti
alter table bookings
    add constraint bookings_slot_type_check
    check (slot_type in ('personal-training', 'small-group', 'group-class'));

-- payment_method: nullable, ma se valorizzato solo valori noti
alter table bookings
    add constraint bookings_payment_method_check
    check (payment_method is null or payment_method in (
        'contanti', 'carta', 'iban', 'credito', 'lezione-gratuita'
    ));

-- cancelled_payment_method: stessa logica
alter table bookings
    add constraint bookings_cancelled_payment_method_check
    check (cancelled_payment_method is null or cancelled_payment_method in (
        'contanti', 'carta', 'iban', 'credito', 'lezione-gratuita'
    ));

-- credit_applied non può essere negativo
alter table bookings
    add constraint bookings_credit_applied_check
    check (credit_applied >= 0);

-- ─── INDEXES: performance query ───────────────────────────────────────────────

-- "Le mie prenotazioni" → user_id + date
create index if not exists bookings_user_date_idx
    on bookings (user_id, date);

-- Filtri admin per stato + data (es. tutte le cancellation_requested di oggi)
create index if not exists bookings_status_date_idx
    on bookings (status, date);

-- Controllo disponibilità slot → date + time + status
create index if not exists bookings_date_time_status_idx
    on bookings (date, time, status);
