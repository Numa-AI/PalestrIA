-- ─── RPC admin_delete_debt_entry ─────────────────────────────────────────────
-- Elimina una singola voce di debito manuale per data e ricalcola il saldo.
-- Se la history è vuota dopo l'eliminazione, cancella l'intera riga.
--
-- Parametri:
--   p_email      email del cliente
--   p_entry_date data ISO della voce (identifica la voce nella history JSONB)
--
-- Ritorna JSONB: { success, new_balance, deleted_row }

CREATE OR REPLACE FUNCTION admin_delete_debt_entry(
    p_email      TEXT,
    p_entry_date TEXT
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

    -- ── Leggi la riga con lock ───────────────────────────────────────────────
    SELECT history INTO v_history
    FROM   manual_debts
    WHERE  lower(email) = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_found');
    END IF;

    -- ── Ricostruisci history escludendo la voce da eliminare ─────────────────
    -- Cerca la PRIMA voce con date = p_entry_date E amount > 0
    FOR v_i IN 0 .. jsonb_array_length(v_history) - 1 LOOP
        v_elem := v_history -> v_i;
        IF NOT v_found
           AND (v_elem ->> 'date') = p_entry_date
           AND (v_elem ->> 'amount')::numeric > 0 THEN
            v_found := true;  -- salta questa voce (la eliminiamo)
        ELSE
            v_new_history := v_new_history || jsonb_build_array(v_elem);
        END IF;
    END LOOP;

    IF NOT v_found THEN
        RETURN jsonb_build_object('success', false, 'error', 'entry_not_found');
    END IF;

    -- ── Ricalcola balance = max(0, somma degli amount rimanenti) ─────────────
    FOR v_i IN 0 .. jsonb_array_length(v_new_history) - 1 LOOP
        v_balance := v_balance + (v_new_history -> v_i ->> 'amount')::numeric;
    END LOOP;
    v_balance := round(greatest(0, v_balance)::numeric, 2);

    -- ── Se history vuota, elimina la riga ────────────────────────────────────
    IF jsonb_array_length(v_new_history) = 0 THEN
        DELETE FROM manual_debts WHERE lower(email) = v_email;
        RETURN jsonb_build_object('success', true, 'new_balance', 0, 'deleted_row', true);
    END IF;

    -- ── Aggiorna ─────────────────────────────────────────────────────────────
    UPDATE manual_debts
    SET    balance = v_balance,
           history = v_new_history
    WHERE  lower(email) = v_email;

    RETURN jsonb_build_object('success', true, 'new_balance', v_balance, 'deleted_row', false);
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_debt_entry FROM public;
GRANT EXECUTE ON FUNCTION admin_delete_debt_entry TO authenticated;
