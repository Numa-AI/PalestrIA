-- ─── RPC admin_add_debt ──────────────────────────────────────────────────────
-- Aggiunge un debito manuale in modo atomico:
--   1. Crea la riga manual_debts se non esiste
--   2. Aggiorna balance (floor a 0)
--   3. Appende voce in history JSONB
-- security definer → bypassa RLS, ma controlla is_admin() esplicitamente.
--
-- Parametri:
--   p_email      email del cliente (chiave unica)
--   p_whatsapp   telefono del cliente (opzionale)
--   p_name       nome del cliente
--   p_amount     importo (positivo = aggiungi debito)
--   p_note       nota (es. "Debito manuale", "Mora 50% ...")
--   p_method     metodo pagamento (opzionale)
--   p_entry_type tipo voce (opzionale, es. 'mora')
--
-- Ritorna JSONB: { success, new_balance }

CREATE OR REPLACE FUNCTION admin_add_debt(
    p_email      TEXT,
    p_whatsapp   TEXT    DEFAULT NULL,
    p_name       TEXT    DEFAULT '',
    p_amount     NUMERIC DEFAULT 0,
    p_note       TEXT    DEFAULT '',
    p_method     TEXT    DEFAULT '',
    p_entry_type TEXT    DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email    TEXT := lower(trim(p_email));
    v_balance  NUMERIC(10,2);
    v_now      TIMESTAMPTZ := now();
    v_entry    JSONB;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    IF p_amount = 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'amount_zero');
    END IF;

    -- ── 1. Trova o crea la riga manual_debts ─────────────────────────────────
    SELECT balance INTO v_balance
    FROM   manual_debts
    WHERE  lower(email) = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO manual_debts (name, whatsapp, email, balance, history)
        VALUES (p_name, p_whatsapp, v_email, 0, '[]'::jsonb)
        RETURNING balance INTO v_balance;
    END IF;

    -- ── 2. Aggiorna balance (floor a 0) ─────────────────────────────────────
    v_balance := round(greatest(0, (v_balance + p_amount))::numeric, 2);

    -- ── 3. Costruisci voce history ──────────────────────────────────────────
    v_entry := jsonb_build_object(
        'date',   v_now,
        'amount', p_amount,
        'note',   p_note,
        'method', p_method
    );
    IF p_entry_type <> '' THEN
        v_entry := v_entry || jsonb_build_object('entryType', p_entry_type);
    END IF;

    -- ── 4. Scrivi ───────────────────────────────────────────────────────────
    UPDATE manual_debts
    SET    balance = v_balance,
           name    = COALESCE(NULLIF(p_name, ''), name),
           history = history || jsonb_build_array(v_entry)
    WHERE  lower(email) = v_email;

    RETURN jsonb_build_object(
        'success',     true,
        'new_balance', v_balance
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_add_debt FROM public;
GRANT EXECUTE ON FUNCTION admin_add_debt TO authenticated;
