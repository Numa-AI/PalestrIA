-- ─── RPC admin_edit_credit_entry ─────────────────────────────────────────────
-- Modifica importo, nota e metodo di una voce credit_history e ricalcola il saldo.

CREATE OR REPLACE FUNCTION admin_edit_credit_entry(
    p_email      TEXT,
    p_entry_date TEXT,
    p_new_amount NUMERIC,
    p_new_note   TEXT DEFAULT '',
    p_new_method TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email     TEXT := lower(trim(p_email));
    v_credit_id UUID;
    v_row_id    UUID;
    v_old_amt   NUMERIC(10,2);
    v_balance   NUMERIC(10,2);
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT id INTO v_credit_id
    FROM   credits
    WHERE  lower(email) = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_found');
    END IF;

    -- Cerca la voce per data (stesso approccio di delete)
    SELECT id, amount INTO v_row_id, v_old_amt
    FROM   credit_history
    WHERE  credit_id = v_credit_id
           AND to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') = p_entry_date
           AND (amount != 0 OR coalesce(display_amount, 0) > 0)
    ORDER BY created_at
    LIMIT 1;

    IF v_row_id IS NULL THEN
        SELECT id, amount INTO v_row_id, v_old_amt
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

    -- Preserva il segno originale
    UPDATE credit_history
    SET    amount = CASE WHEN v_old_amt >= 0 THEN p_new_amount ELSE -p_new_amount END,
           note   = p_new_note,
           method = coalesce(p_new_method, '')
    WHERE  id = v_row_id;

    -- Ricalcola balance
    SELECT coalesce(sum(amount), 0) INTO v_balance
    FROM   credit_history
    WHERE  credit_id = v_credit_id;
    v_balance := round(greatest(0, v_balance)::numeric, 2);

    UPDATE credits SET balance = v_balance WHERE id = v_credit_id;

    RETURN jsonb_build_object('success', true, 'new_balance', v_balance);
END;
$$;

REVOKE ALL ON FUNCTION admin_edit_credit_entry FROM public;
GRANT EXECUTE ON FUNCTION admin_edit_credit_entry TO authenticated;


-- ─── RPC admin_edit_debt_entry ──────────────────────────────────────────────
-- Modifica importo e nota di una voce nella history JSONB di manual_debts.

CREATE OR REPLACE FUNCTION admin_edit_debt_entry(
    p_email      TEXT,
    p_entry_date TEXT,
    p_new_amount NUMERIC,
    p_new_note   TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email       TEXT := lower(trim(p_email));
    v_history     JSONB;
    v_new_history JSONB := '[]'::jsonb;
    v_found       BOOLEAN := false;
    v_balance     NUMERIC(10,2) := 0;
    v_elem        JSONB;
    v_i           INTEGER;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    SELECT history INTO v_history
    FROM   manual_debts
    WHERE  lower(email) = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_found');
    END IF;

    FOR v_i IN 0 .. jsonb_array_length(v_history) - 1 LOOP
        v_elem := v_history -> v_i;
        IF NOT v_found
           AND (v_elem ->> 'date') = p_entry_date
           AND (v_elem ->> 'amount')::numeric > 0 THEN
            -- Modifica questa voce
            v_elem := jsonb_set(v_elem, '{amount}', to_jsonb(p_new_amount));
            v_elem := jsonb_set(v_elem, '{note}', to_jsonb(p_new_note));
            v_found := true;
        END IF;
        v_new_history := v_new_history || jsonb_build_array(v_elem);
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object('success', false, 'error', 'entry_not_found');
    END IF;

    -- Ricalcola balance
    FOR v_i IN 0 .. jsonb_array_length(v_new_history) - 1 LOOP
        v_balance := v_balance + (v_new_history -> v_i ->> 'amount')::numeric;
    END LOOP;
    v_balance := round(greatest(0, v_balance)::numeric, 2);

    UPDATE manual_debts
    SET    balance = v_balance,
           history = v_new_history
    WHERE  lower(email) = v_email;

    RETURN jsonb_build_object('success', true, 'new_balance', v_balance);
END;
$$;

REVOKE ALL ON FUNCTION admin_edit_debt_entry FROM public;
GRANT EXECUTE ON FUNCTION admin_edit_debt_entry TO authenticated;
