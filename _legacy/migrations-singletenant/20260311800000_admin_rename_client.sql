-- ─── RPC admin_rename_client ─────────────────────────────────────────────────
-- Aggiorna atomicamente nome/email/whatsapp di un cliente su tutte le tabelle:
--   bookings, credits, manual_debts, profiles
--
-- Parametri:
--   p_old_email    email attuale del cliente
--   p_old_whatsapp whatsapp attuale (per matching su bookings senza email)
--   p_new_name     nuovo nome
--   p_new_email    nuova email
--   p_new_whatsapp nuovo whatsapp
--
-- Ritorna JSONB: { success, bookings_updated, credits_updated, debts_updated, profiles_updated }

CREATE OR REPLACE FUNCTION admin_rename_client(
    p_old_email    TEXT,
    p_old_whatsapp TEXT DEFAULT NULL,
    p_new_name     TEXT DEFAULT '',
    p_new_email    TEXT DEFAULT '',
    p_new_whatsapp TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_old_email TEXT := lower(trim(p_old_email));
    v_new_email TEXT := lower(trim(p_new_email));
    v_bookings  INTEGER;
    v_credits   INTEGER;
    v_debts     INTEGER;
    v_profiles  INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── 1. Bookings ─────────────────────────────────────────────────────────
    UPDATE bookings
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  lower(email) = v_old_email
       OR  (p_old_whatsapp IS NOT NULL AND p_old_whatsapp <> '' AND whatsapp = p_old_whatsapp);
    GET DIAGNOSTICS v_bookings = ROW_COUNT;

    -- ── 2. Credits ──────────────────────────────────────────────────────────
    UPDATE credits
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  email = v_old_email;
    GET DIAGNOSTICS v_credits = ROW_COUNT;

    -- ── 3. Manual debts ─────────────────────────────────────────────────────
    UPDATE manual_debts
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  lower(email) = v_old_email;
    GET DIAGNOSTICS v_debts = ROW_COUNT;

    -- ── 4. Profiles ─────────────────────────────────────────────────────────
    UPDATE profiles
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  lower(email) = v_old_email
       OR  (p_old_whatsapp IS NOT NULL AND p_old_whatsapp <> '' AND whatsapp = p_old_whatsapp);
    GET DIAGNOSTICS v_profiles = ROW_COUNT;

    RETURN jsonb_build_object(
        'success',          true,
        'bookings_updated', v_bookings,
        'credits_updated',  v_credits,
        'debts_updated',    v_debts,
        'profiles_updated', v_profiles
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_rename_client FROM public;
GRANT EXECUTE ON FUNCTION admin_rename_client TO authenticated;
