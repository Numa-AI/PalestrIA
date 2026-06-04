-- ─── RPC admin_delete_credit_entry ─────────────────────────────────────────────
-- Elimina una singola voce di credito per data e ricalcola il saldo.
-- Se la history è vuota dopo l'eliminazione, cancella l'intera riga.
--
-- Parametri:
--   p_email      email del cliente
--   p_entry_date data ISO della voce (identifica la voce nella credit_history)
--
-- Ritorna JSONB: { success, new_balance, deleted_row }

CREATE OR REPLACE FUNCTION admin_delete_credit_entry(
    p_email      TEXT,
    p_entry_date TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email      TEXT := lower(trim(p_email));
    v_credit_id  UUID;
    v_balance    NUMERIC(10,2) := 0;
    v_free_bal   NUMERIC(10,2) := 0;
    v_found      BOOLEAN := false;
    v_row_id     UUID;
    v_remaining  INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── Trova il record credits per email ──────────────────────────────────────
    SELECT id INTO v_credit_id
    FROM   credits
    WHERE  lower(email) = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_found');
    END IF;

    -- ── Cerca la voce da eliminare in credit_history ───────────────────────────
    -- Cerca la PRIMA voce con created_at corrispondente e amount > 0 (o amount = 0 con display_amount > 0)
    SELECT id INTO v_row_id
    FROM   credit_history
    WHERE  credit_id = v_credit_id
           AND to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') = p_entry_date
           AND (amount != 0 OR coalesce(display_amount, 0) > 0)
    ORDER BY created_at
    LIMIT 1;

    IF v_row_id IS NULL THEN
        -- Prova match meno stringente (senza millisecondi)
        SELECT id INTO v_row_id
        FROM   credit_history
        WHERE  credit_id = v_credit_id
               AND abs(EXTRACT(EPOCH FROM (created_at - p_entry_date::timestamptz))) < 2
               AND (amount != 0 OR coalesce(display_amount, 0) > 0)
        ORDER BY created_at
        LIMIT 1;
    END IF;

    IF v_row_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'entry_not_found');
    END IF;

    -- ── Elimina la voce ────────────────────────────────────────────────────────
    DELETE FROM credit_history WHERE id = v_row_id;
    v_found := true;

    -- ── Ricalcola balance = max(0, somma degli amount rimanenti) ───────────────
    SELECT coalesce(sum(amount), 0) INTO v_balance
    FROM   credit_history
    WHERE  credit_id = v_credit_id;
    v_balance := round(greatest(0, v_balance)::numeric, 2);

    -- ── Conta righe rimanenti ─────────────────────────────────────────────────
    SELECT count(*) INTO v_remaining
    FROM   credit_history
    WHERE  credit_id = v_credit_id;

    -- ── Se history vuota, elimina l'intero record credits ─────────────────────
    IF v_remaining = 0 THEN
        DELETE FROM credits WHERE id = v_credit_id;
        RETURN jsonb_build_object('success', true, 'new_balance', 0, 'deleted_row', true);
    END IF;

    -- ── Aggiorna il saldo ─────────────────────────────────────────────────────
    UPDATE credits
    SET    balance = v_balance
    WHERE  id = v_credit_id;

    RETURN jsonb_build_object('success', true, 'new_balance', v_balance, 'deleted_row', false);
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_credit_entry FROM public;
GRANT EXECUTE ON FUNCTION admin_delete_credit_entry TO authenticated;
