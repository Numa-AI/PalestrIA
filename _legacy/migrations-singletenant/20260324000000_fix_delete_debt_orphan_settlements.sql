-- ─── Fix admin_delete_debt_entry: rimuovi voci di saldamento orfane ──────────
-- Quando si elimina un debito (+X), le voci di saldamento (-X) corrispondenti
-- restavano nella history e apparivano nel registro come "Debito Saldato".
-- Ora, dopo l'eliminazione, se la somma diventa negativa rimuoviamo le voci
-- negative più recenti fino a riportare la somma >= 0.

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
    v_sum         NUMERIC(10,2) := 0;
    v_clean       JSONB := '[]'::jsonb;
    v_neg_excess  NUMERIC(10,2);
    v_amt         NUMERIC(10,2);
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

    -- ── Calcola somma delle voci rimanenti ──────────────────────────────────
    v_sum := 0;
    FOR v_i IN 0 .. jsonb_array_length(v_new_history) - 1 LOOP
        v_sum := v_sum + (v_new_history -> v_i ->> 'amount')::numeric;
    END LOOP;

    -- ── Se la somma è negativa, rimuovi voci negative orfane ────────────────
    -- Scandiamo dal fondo (più recenti) e saltiamo le voci negative fino
    -- a riportare la somma >= 0.
    IF v_sum < 0 THEN
        v_neg_excess := -v_sum;  -- quanto dobbiamo recuperare
        v_clean := '[]'::jsonb;

        -- Prima passata: dall'ultimo al primo, marca le voci negative da rimuovere
        -- Ricostruiamo al contrario poi invertiamo
        FOR v_i IN REVERSE jsonb_array_length(v_new_history) - 1 .. 0 LOOP
            v_elem := v_new_history -> v_i;
            v_amt  := (v_elem ->> 'amount')::numeric;

            IF v_amt < 0 AND v_neg_excess > 0 THEN
                -- Rimuovi questa voce negativa
                v_neg_excess := v_neg_excess + v_amt;  -- v_amt è negativo, quindi somma
                IF v_neg_excess < 0 THEN
                    v_neg_excess := 0;
                END IF;
            ELSE
                v_clean := jsonb_build_array(v_elem) || v_clean;
            END IF;
        END LOOP;

        v_new_history := v_clean;
    END IF;

    -- ── Ricalcola balance ───────────────────────────────────────────────────
    v_balance := 0;
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
