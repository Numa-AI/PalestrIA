-- ─── RPC: admin_delete_client_data ───────────────────────────────────────────
-- Elimina tutti i dati di un cliente (prenotazioni, crediti, debiti, bonus).
-- Solo admin può chiamare questa funzione.

CREATE OR REPLACE FUNCTION admin_delete_client_data(
    p_email TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email       TEXT;
    v_del_bookings INT;
    v_del_credits  INT;
    v_del_debts    INT;
    v_del_bonuses  INT;
    v_credit_id    UUID;
BEGIN
    -- Solo admin
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    v_email := lower(trim(p_email));
    IF v_email IS NULL OR v_email = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'email_required');
    END IF;

    -- 1. Elimina credit_history (FK su credits.id)
    SELECT id INTO v_credit_id FROM credits WHERE email = v_email;
    IF FOUND THEN
        DELETE FROM credit_history WHERE credit_id = v_credit_id;
    END IF;

    -- 2. Elimina bookings
    DELETE FROM bookings WHERE email = v_email;
    GET DIAGNOSTICS v_del_bookings = ROW_COUNT;

    -- 3. Elimina credits
    DELETE FROM credits WHERE email = v_email;
    GET DIAGNOSTICS v_del_credits = ROW_COUNT;

    -- 4. Elimina manual_debts
    DELETE FROM manual_debts WHERE email = v_email;
    GET DIAGNOSTICS v_del_debts = ROW_COUNT;

    -- 5. Elimina bonuses
    DELETE FROM bonuses WHERE email = v_email;
    GET DIAGNOSTICS v_del_bonuses = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'deleted_bookings', v_del_bookings,
        'deleted_credits', v_del_credits,
        'deleted_debts', v_del_debts,
        'deleted_bonuses', v_del_bonuses
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_client_data FROM public;
GRANT EXECUTE ON FUNCTION admin_delete_client_data TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_client_data TO service_role;
