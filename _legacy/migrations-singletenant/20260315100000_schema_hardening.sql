-- ─── Schema hardening: FK fix, audit triggers, optimistic locking ─────────────
-- Tutte le modifiche sono additive e non cambiano la logica applicativa.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. bonuses FK: CASCADE → SET NULL (non eliminare bonus se si cancella il profilo)
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE bonuses DROP CONSTRAINT IF EXISTS bonuses_user_id_fkey;
ALTER TABLE bonuses
    ADD CONSTRAINT bonuses_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES profiles(id) ON DELETE SET NULL;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. credit_history: colonna booking_id per tracciare contesto prenotazione
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE credit_history ADD COLUMN IF NOT EXISTS booking_id UUID DEFAULT NULL;

-- Indice per lookup rapido
CREATE INDEX IF NOT EXISTS idx_credit_history_booking_id
    ON credit_history(booking_id) WHERE booking_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. Optimistic locking: updated_at su credits e manual_debts
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE credits      ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE manual_debts ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- Trigger auto-update updated_at (riuso la funzione _trg_set_updated_at se esiste)
CREATE OR REPLACE FUNCTION _trg_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_credits_updated_at'
    ) THEN
        CREATE TRIGGER trg_credits_updated_at
            BEFORE UPDATE ON credits
            FOR EACH ROW EXECUTE FUNCTION _trg_set_updated_at();
    END IF;
END $$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_manual_debts_updated_at'
    ) THEN
        CREATE TRIGGER trg_manual_debts_updated_at
            BEFORE UPDATE ON manual_debts
            FOR EACH ROW EXECUTE FUNCTION _trg_set_updated_at();
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Audit triggers su credits, manual_debts, bonuses
--    Logga tutte le modifiche fatte da admin nell'admin_audit_log,
--    come già avviene per bookings tramite _trg_audit_booking_change.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ── Credits audit trigger ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _trg_audit_credit_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF is_admin() THEN
        IF TG_OP = 'DELETE' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'delete_credit', OLD.email,
                   jsonb_build_object('credit_id', OLD.id, 'old_balance', OLD.balance)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN OLD;
        END IF;

        IF TG_OP = 'INSERT' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'insert_credit', NEW.email,
                   jsonb_build_object('credit_id', NEW.id, 'balance', NEW.balance)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN NEW;
        END IF;

        -- UPDATE: logga solo se balance è cambiato
        IF OLD.balance IS DISTINCT FROM NEW.balance THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'update_credit', NEW.email,
                   jsonb_build_object(
                       'credit_id', NEW.id,
                       'old_balance', OLD.balance,
                       'new_balance', NEW.balance
                   )
            FROM auth.users u WHERE u.id = auth.uid();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_audit_credit_change'
    ) THEN
        CREATE TRIGGER trg_audit_credit_change
            AFTER INSERT OR UPDATE OR DELETE ON credits
            FOR EACH ROW EXECUTE FUNCTION _trg_audit_credit_change();
    END IF;
END $$;

-- ── Manual debts audit trigger ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _trg_audit_debt_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF is_admin() THEN
        IF TG_OP = 'DELETE' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'delete_debt', OLD.email,
                   jsonb_build_object('debt_id', OLD.id, 'old_balance', OLD.balance)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN OLD;
        END IF;

        IF TG_OP = 'INSERT' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'insert_debt', NEW.email,
                   jsonb_build_object('debt_id', NEW.id, 'balance', NEW.balance)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN NEW;
        END IF;

        IF OLD.balance IS DISTINCT FROM NEW.balance THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'update_debt', NEW.email,
                   jsonb_build_object(
                       'debt_id', NEW.id,
                       'old_balance', OLD.balance,
                       'new_balance', NEW.balance
                   )
            FROM auth.users u WHERE u.id = auth.uid();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_audit_debt_change'
    ) THEN
        CREATE TRIGGER trg_audit_debt_change
            AFTER INSERT OR UPDATE OR DELETE ON manual_debts
            FOR EACH ROW EXECUTE FUNCTION _trg_audit_debt_change();
    END IF;
END $$;

-- ── Bonuses audit trigger ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _trg_audit_bonus_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF is_admin() THEN
        IF TG_OP = 'DELETE' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'delete_bonus', OLD.email,
                   jsonb_build_object('bonus_id', OLD.id, 'name', OLD.name)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN OLD;
        END IF;

        IF TG_OP = 'INSERT' THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'insert_bonus', NEW.email,
                   jsonb_build_object('bonus_id', NEW.id, 'name', NEW.name, 'bonus', NEW.bonus)
            FROM auth.users u WHERE u.id = auth.uid();
            RETURN NEW;
        END IF;

        IF OLD.bonus IS DISTINCT FROM NEW.bonus THEN
            INSERT INTO admin_audit_log (admin_id, admin_email, action, target_email, details)
            SELECT auth.uid(), u.email, 'update_bonus', NEW.email,
                   jsonb_build_object(
                       'bonus_id', NEW.id,
                       'old_bonus', OLD.bonus,
                       'new_bonus', NEW.bonus
                   )
            FROM auth.users u WHERE u.id = auth.uid();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_audit_bonus_change'
    ) THEN
        CREATE TRIGGER trg_audit_bonus_change
            AFTER INSERT OR UPDATE OR DELETE ON bonuses
            FOR EACH ROW EXECUTE FUNCTION _trg_audit_bonus_change();
    END IF;
END $$;
