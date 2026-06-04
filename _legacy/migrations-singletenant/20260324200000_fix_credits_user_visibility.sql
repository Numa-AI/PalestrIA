-- ─── FIX: utenti non vedono il proprio credito in prenotazioni ──────────────
-- Causa: credits.user_id resta NULL perché il trigger auto_link_credit_user_id
-- usa un confronto email case-sensitive, e scatta PRIMA del trigger di
-- normalizzazione (ordine alfabetico: credits_auto_link_user < trg_normalize_email).
-- manual_debts funziona perché il suo trigger usa già lower().
--
-- Fix:
--   1. Trigger credits: lower() come manual_debts
--   2. Trigger link_anonymous_on_register: lower() su bookings e credits
--   3. Normalize email su profiles (mancava)
--   4. Backfill user_id NULL su credits
--   5. RLS fallback su email come rete di sicurezza

-- ── 1. Fix trigger auto_link_credit_user_id: case-insensitive ───────────────
CREATE OR REPLACE FUNCTION auto_link_credit_user_id()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NEW.user_id IS NULL AND NEW.email IS NOT NULL THEN
        SELECT id INTO NEW.user_id
        FROM profiles
        WHERE lower(email) = lower(NEW.email)
        LIMIT 1;
    END IF;
    RETURN NEW;
END;
$$;

-- ── 2. Fix trigger link_anonymous_on_register: case-insensitive ─────────────
CREATE OR REPLACE FUNCTION link_anonymous_on_register()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE bookings SET user_id = NEW.id
    WHERE lower(email) = lower(NEW.email) AND user_id IS NULL;

    UPDATE credits SET user_id = NEW.id
    WHERE lower(email) = lower(NEW.email) AND user_id IS NULL;

    RETURN NEW;
END;
$$;

-- ── 3. Normalize email su profiles (già presente su bookings/credits/manual_debts/bonuses) ─
DROP TRIGGER IF EXISTS trg_normalize_email ON profiles;
CREATE TRIGGER trg_normalize_email
    BEFORE INSERT OR UPDATE OF email ON profiles
    FOR EACH ROW EXECUTE FUNCTION normalize_email();

UPDATE profiles
SET email = lower(trim(email))
WHERE email IS DISTINCT FROM lower(trim(email));

-- ── 4. Backfill: collega credits orfani ai profili ──────────────────────────
UPDATE credits c
SET user_id = p.id
FROM profiles p
WHERE lower(c.email) = lower(p.email)
  AND c.user_id IS NULL;

-- ── 5. RLS credits: fallback su email se user_id è NULL ─────────────────────
DROP POLICY IF EXISTS "credits_select_own" ON credits;
CREATE POLICY "credits_select_own"
    ON credits FOR SELECT TO authenticated
    USING (
        user_id = auth.uid()
        OR (
            user_id IS NULL
            AND email = (SELECT email FROM profiles WHERE id = auth.uid())
        )
    );

DROP POLICY IF EXISTS "credit_history_select_own" ON credit_history;
CREATE POLICY "credit_history_select_own"
    ON credit_history FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM credits
            WHERE credits.id = credit_history.credit_id
              AND (
                  credits.user_id = auth.uid()
                  OR (
                      credits.user_id IS NULL
                      AND credits.email = (SELECT email FROM profiles WHERE id = auth.uid())
                  )
              )
        )
    );
