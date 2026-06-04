-- ─── Colonne aggiuntive credit_history ──────────────────────────────────────
-- Aggiunge 3 colonne alla tabella credit_history:
--   booking_ref    UUID  → riferimento alla prenotazione (per nascondere/trovare voci)
--   hidden         BOOL  → voce nascosta (es. dopo cambio metodo pagamento)
--   display_amount NUMERIC → importo visualizzato (diverso da amount, es. €30 ricevuto ma amount=0)

ALTER TABLE credit_history
    ADD COLUMN IF NOT EXISTS booking_ref    UUID,
    ADD COLUMN IF NOT EXISTS hidden         BOOLEAN       NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS display_amount NUMERIC(10,2);

CREATE INDEX IF NOT EXISTS credit_history_booking_ref_idx
    ON credit_history (booking_ref)
    WHERE booking_ref IS NOT NULL;

CREATE INDEX IF NOT EXISTS credit_history_hidden_idx
    ON credit_history (hidden)
    WHERE hidden = true;
