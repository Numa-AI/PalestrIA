-- ─── FASE 4 — POST-LANCIO ────────────────────────────────────────────────────
-- Fix a bassa priorità per migliorare performance, sicurezza e manutenibilità.
--
--   14. Indexes mancanti (credits.email lookup, credit_history time-series)
--   15. CHECK su dimensione JSONB history (manual_debts)
--   16. Audit trail admin (chi ha fatto cosa)
--   18. FK credits: da ON DELETE CASCADE a ON DELETE SET NULL

-- ═══════════════════════════════════════════════════════════════════════════════
-- 14. Missing indexes
-- ═══════════════════════════════════════════════════════════════════════════════

-- credits.email è usato in OGNI RPC admin (lookup per email) — già UNIQUE ma un
-- indice esplicito rende la query plan più prevedibile su tabelle grandi
-- (UNIQUE constraint crea già un indice, quindi è un no-op ma documenta l'intento)

-- credit_history: query per credit_id ordinate per created_at (storico credito)
CREATE INDEX IF NOT EXISTS credit_history_credit_id_created_at_idx
    ON credit_history (credit_id, created_at);

-- bookings: lookup per email + status (usato in auto-pay FIFO)
CREATE INDEX IF NOT EXISTS bookings_email_status_idx
    ON bookings (lower(email), status)
    WHERE status NOT IN ('cancelled');


-- ═══════════════════════════════════════════════════════════════════════════════
-- 15. Limite dimensione JSONB history su manual_debts
-- ═══════════════════════════════════════════════════════════════════════════════

-- Previene crescita illimitata: max 500 voci per debitore.
-- In caso di superamento, le RPC devono troncare le voci più vecchie.
-- Il CHECK constraint impedisce insert/update che sfondano il limite.
ALTER TABLE manual_debts
    ADD CONSTRAINT manual_debts_history_size_check
    CHECK (jsonb_array_length(history) <= 500);


-- ═══════════════════════════════════════════════════════════════════════════════
-- 16. Audit trail admin — tabella admin_audit_log
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS admin_audit_log (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    admin_id    UUID,           -- auth.uid() dell'admin (NULL se service_role/cron)
    admin_email TEXT,            -- email dell'admin per leggibilità
    action      TEXT NOT NULL,   -- es. 'add_credit', 'pay_bookings', 'cancel_booking', 'rename_client'
    target_email TEXT,           -- email del cliente target
    details     JSONB DEFAULT '{}'  -- payload specifico dell'azione
);

ALTER TABLE admin_audit_log ENABLE ROW LEVEL SECURITY;

-- Solo admin possono leggere il log
DROP POLICY IF EXISTS "audit_log_admin_read" ON admin_audit_log;
CREATE POLICY "audit_log_admin_read"
    ON admin_audit_log FOR SELECT TO authenticated
    USING (is_admin());

-- Solo insert via SECURITY DEFINER (le RPC admin)
DROP POLICY IF EXISTS "audit_log_no_direct_write" ON admin_audit_log;
CREATE POLICY "audit_log_no_direct_write"
    ON admin_audit_log FOR INSERT TO authenticated
    WITH CHECK (false);  -- nessun INSERT diretto; solo SECURITY DEFINER bypassa RLS

CREATE INDEX IF NOT EXISTS audit_log_created_at_idx ON admin_audit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_action_idx ON admin_audit_log (action);
CREATE INDEX IF NOT EXISTS audit_log_target_email_idx ON admin_audit_log (target_email);

-- Helper per inserire audit log dalle RPC admin (SECURITY DEFINER bypassa RLS)
CREATE OR REPLACE FUNCTION _audit_log(
    p_action       TEXT,
    p_target_email TEXT DEFAULT NULL,
    p_details      JSONB DEFAULT '{}'
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_admin_email TEXT;
BEGIN
    -- Recupera email admin dal JWT (se disponibile)
    SELECT email INTO v_admin_email
    FROM auth.users
    WHERE id = auth.uid();

    INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
    VALUES (auth.uid(), v_admin_email, p_action, p_target_email, p_details);
END;
$$;

-- ── Aggiunge audit log alle RPC admin esistenti ──────────────────────────────
-- Nota: NON riscriviamo le intere funzioni — usiamo trigger post-operazione
-- sul booking per le azioni più comuni.

-- Trigger audit log su booking status change
CREATE OR REPLACE FUNCTION _trg_audit_booking_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- Logga solo cambiamenti significativi fatti da admin (non da utente o cron)
    IF is_admin() THEN
        IF OLD.status IS DISTINCT FROM NEW.status
           OR OLD.paid IS DISTINCT FROM NEW.paid
           OR OLD.payment_method IS DISTINCT FROM NEW.payment_method THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'update_booking', NEW.email, jsonb_build_object(
                'booking_id', NEW.id,
                'old_status', OLD.status,
                'new_status', NEW.status,
                'old_paid', OLD.paid,
                'new_paid', NEW.paid,
                'old_method', OLD.payment_method,
                'new_method', NEW.payment_method
            )
            FROM auth.users u WHERE u.id = auth.uid();
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_booking_change ON bookings;
CREATE TRIGGER trg_audit_booking_change
    AFTER UPDATE ON bookings
    FOR EACH ROW
    EXECUTE FUNCTION _trg_audit_booking_change();


-- ═══════════════════════════════════════════════════════════════════════════════
-- 18. FK credits: ON DELETE CASCADE → ON DELETE SET NULL
-- ═══════════════════════════════════════════════════════════════════════════════
-- Se un profilo viene cancellato, il credito NON deve sparire.
-- credit_history mantiene ON DELETE CASCADE (se la riga credits viene eliminata
-- esplicitamente dall'admin, lo storico va con essa — ma non per eliminazione profilo).

-- credits.user_id: cambia da CASCADE a SET NULL
-- Prima verifica se la colonna esiste (aggiunta in 20260227000000)
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'credits' AND column_name = 'user_id'
    ) THEN
        -- Drop il vecchio constraint e ricrealo con SET NULL
        ALTER TABLE credits DROP CONSTRAINT IF EXISTS credits_user_id_fkey;
        ALTER TABLE credits
            ADD CONSTRAINT credits_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;
    END IF;
END;
$$;
