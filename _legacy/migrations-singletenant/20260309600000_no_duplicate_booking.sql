-- ─── ANTI-DOPPIA-PRENOTAZIONE ────────────────────────────────────────────────
-- Impedisce che lo stesso utente registrato prenoti due volte lo stesso slot.
-- Indice parziale:
--   - esclude booking 'cancelled' (un utente può riprenotare dopo cancellazione)
--   - esclude booking anonimi (user_id NULL) — non identificabili univocamente
create unique index if not exists bookings_no_duplicate_user_slot
    on bookings (user_id, date, time)
    where status != 'cancelled' and user_id is not null;
