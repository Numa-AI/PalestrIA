-- ─── Stripe top-up: colonna stripe_session_id per idempotenza ─────────────────
ALTER TABLE credit_history
    ADD COLUMN IF NOT EXISTS stripe_session_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS credit_history_stripe_session_idx
    ON credit_history (stripe_session_id)
    WHERE stripe_session_id IS NOT NULL;

-- ─── RPC: stripe_topup_credit ────────────────────────────────────────────────
-- Chiamata dalla Edge Function stripe-webhook (con service_role_key).
-- Aggiunge credito all'utente e registra la transazione con idempotenza.
-- NON auto-paga le prenotazioni (l'utente vedrà il credito e verrà
-- applicato automaticamente dalla prossima prenotazione o dal polling).
CREATE OR REPLACE FUNCTION stripe_topup_credit(
    p_user_id          UUID,
    p_amount           NUMERIC,
    p_stripe_session_id TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_credit_id UUID;
    v_balance   NUMERIC(10,2);
    v_email     TEXT;
BEGIN
    -- Idempotency: skip if already processed
    IF EXISTS (
        SELECT 1 FROM credit_history WHERE stripe_session_id = p_stripe_session_id
    ) THEN
        RETURN jsonb_build_object('success', true, 'already_processed', true);
    END IF;

    -- Lookup user email
    SELECT email INTO v_email FROM profiles WHERE id = p_user_id;
    IF v_email IS NULL THEN
        RAISE EXCEPTION 'Utente non trovato: %', p_user_id;
    END IF;

    v_email := lower(trim(v_email));

    -- Find or create credits row
    SELECT id, balance INTO v_credit_id, v_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO credits (name, whatsapp, email, balance, user_id)
        SELECT p.name, p.whatsapp, v_email, 0, p.id
        FROM   profiles p WHERE p.id = p_user_id
        RETURNING id, balance INTO v_credit_id, v_balance;
    END IF;

    -- Update balance
    v_balance := round((v_balance + p_amount)::numeric, 2);
    UPDATE credits SET balance = v_balance WHERE id = v_credit_id;

    -- Insert history entry
    INSERT INTO credit_history (credit_id, amount, note, method, stripe_session_id)
    VALUES (v_credit_id, p_amount, 'Ricarica online Stripe €' || p_amount, 'stripe', p_stripe_session_id);

    RETURN jsonb_build_object(
        'success',     true,
        'new_balance', v_balance,
        'credit_id',   v_credit_id
    );
END;
$$;

-- Solo service_role può chiamarla (niente public)
REVOKE ALL ON FUNCTION stripe_topup_credit FROM public;
