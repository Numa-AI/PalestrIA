-- ─── FIX SICUREZZA: revoca accesso anon alle RPC crediti ─────────────────
-- apply_credit_on_booking e apply_credit_to_past_bookings erano accessibili
-- ad utenti anonimi. Un attaccante con la anon key poteva chiamarle con una
-- email qualsiasi e prosciugare il credito di un altro utente.
--
-- Entrambe le funzioni sono chiamate SOLO dall'admin (già autenticato):
--   - apply_credit_to_past_bookings → admin-calendar.js, admin-payments.js
--   - apply_credit_on_booking → non usata nel frontend (candidata a rimozione)

REVOKE EXECUTE ON FUNCTION apply_credit_on_booking FROM anon;
REVOKE EXECUTE ON FUNCTION apply_credit_to_past_bookings FROM anon;
