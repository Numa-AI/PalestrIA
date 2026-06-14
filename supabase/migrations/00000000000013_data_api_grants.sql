-- ═══════════════════════════════════════════════════════════════════════════
-- Data API grants — future-proof per il cambio default Supabase (30/10/2026)
-- ═══════════════════════════════════════════════════════════════════════════
-- Contesto: dal 30 ottobre 2026 Supabase NON espone più automaticamente le
-- tabelle dello schema `public` alla Data API (PostgREST / supabase-js). Ogni
-- nuova tabella richiederà un GRANT esplicito.
--
-- Questa migration:
--   1) Conferma i permessi su TUTTE le tabelle/sequenze esistenti (additiva,
--      no-op sulle tabelle attuali che già li hanno per via del default odierno).
--   2) Imposta i DEFAULT PRIVILEGES così che ogni tabella creata d'ora in poi
--      riceva automaticamente i permessi — anche dopo il 30/10/2026.
--
-- Scelta deliberata per QUESTO progetto: si concede SOLO a `authenticated`,
-- NON ad `anon`. Verificato sulle migration: nessuna tabella ha policy RLS
-- `to anon` e il flusso pubblico/anonimo (prenotazione) passa esclusivamente da
-- RPC SECURITY DEFINER (book_slot, get_availability_range, get_slot_availability,
-- get_slot_attendees, is_whatsapp_taken, get_public_org_settings) che hanno già
-- il loro `grant execute ... to anon`. Gli anonimi non toccano mai le tabelle.
--
-- NON si toccano i permessi sulle FUNZIONI: ogni RPC ha già il suo grant
-- esplicito (alcune `authenticated`, alcune anche `anon`, alcune con revoke da
-- anon). Un default automatico su FUNCTIONS esporrebbe ogni nuova RPC ad anon
-- → rischio sicurezza. Si lascia la concessione funzione-per-funzione.
--
-- IMPORTANTE: il GRANT apre solo la "porta" della Data API. La protezione delle
-- righe resta affidata all'RLS: ogni tabella deve comunque avere
-- `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` e le sue policy org-scoped.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 1) Tabelle e sequenze ESISTENTI ─────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT                  ON ALL SEQUENCES  IN SCHEMA public TO authenticated;

-- ─── 2) Default per le tabelle/sequenze FUTURE ───────────────────────────────
-- Si applica agli oggetti creati dal ruolo che esegue questa migration
-- (`postgres`, lo stesso usato dal SQL Editor e da `supabase db push`).
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO authenticated;
