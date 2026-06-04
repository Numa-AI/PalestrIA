-- Fix: cancel_booking_with_refund — booking anonimi (user_id NULL) richiedono admin
-- Prima: qualsiasi utente autenticato poteva cancellare booking senza user_id.
-- Ora: booking senza proprietario → solo admin può cancellare.

CREATE OR REPLACE FUNCTION cancel_booking_with_refund(
    p_booking_id       UUID,
    p_credit_amount    NUMERIC  DEFAULT 0,
    p_credit_note      TEXT     DEFAULT '',
    p_use_bonus        BOOLEAN  DEFAULT false,
    p_with_bonus       BOOLEAN  DEFAULT false,
    p_with_penalty     BOOLEAN  DEFAULT false,
    p_mora_debt_amount NUMERIC  DEFAULT 0,
    p_mora_debt_note   TEXT     DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking   RECORD;
    v_credit_id UUID;
    v_now       TIMESTAMPTZ := now();
    v_entry     JSONB;
BEGIN
    -- ── Leggi il booking CON LOCK per evitare race condition ─────────────────
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- ── Impedisci doppia cancellazione ───────────────────────────────────────
    IF v_booking.status = 'cancelled' THEN
        RETURN jsonb_build_object('success', false, 'error', 'already_cancelled');
    END IF;

    -- ── Autorizzazione: proprietario O admin ─────────────────────────────────
    -- Booking anonimi (user_id NULL): solo admin può cancellare
    IF v_booking.user_id IS NULL AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;
    IF v_booking.user_id IS NOT NULL
       AND v_booking.user_id IS DISTINCT FROM auth.uid()
       AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- ── Aggiorna stato booking ───────────────────────────────────────────────
    UPDATE bookings SET
        status                    = 'cancelled',
        cancelled_at              = v_now,
        cancelled_by              = auth.uid(),
        paid                      = false,
        payment_method            = null,
        credit_applied            = 0,
        cancelled_with_bonus      = p_with_bonus,
        cancelled_with_penalty    = p_with_penalty,
        cancelled_payment_method  = v_booking.payment_method,
        cancelled_paid_at         = v_booking.paid_at
    WHERE id = p_booking_id;

    -- ── Rimborso credito (con lock sulla riga credits) ───────────────────────
    IF p_credit_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        SELECT id INTO v_credit_id
        FROM credits
        WHERE email = lower(trim(v_booking.email))
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, lower(trim(v_booking.email)), p_credit_amount, 0)
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET balance = round((balance + p_credit_amount)::numeric, 2)
            WHERE id = v_credit_id;
        END IF;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, p_credit_amount, p_credit_note, v_now);
    END IF;

    -- ── Mora debito (per booking non pagati) ─────────────────────────────────
    IF p_mora_debt_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        v_entry := jsonb_build_object(
            'date',      v_now,
            'amount',    p_mora_debt_amount,
            'note',      COALESCE(NULLIF(p_mora_debt_note, ''), 'Mora 50%'),
            'method',    '',
            'entryType', 'mora'
        );

        INSERT INTO manual_debts (name, whatsapp, email, balance, history)
        VALUES (
            v_booking.name,
            v_booking.whatsapp,
            lower(trim(v_booking.email)),
            p_mora_debt_amount,
            jsonb_build_array(v_entry)
        )
        ON CONFLICT (email) DO UPDATE
        SET balance = round((manual_debts.balance + p_mora_debt_amount)::numeric, 2),
            history = manual_debts.history || jsonb_build_array(v_entry);
    END IF;

    -- ── Consumo bonus mensile ────────────────────────────────────────────────
    IF p_use_bonus
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        INSERT INTO bonuses (name, whatsapp, email, bonus, last_reset_month)
        VALUES (
            v_booking.name,
            v_booking.whatsapp,
            lower(trim(v_booking.email)),
            0,
            to_char(v_now AT TIME ZONE 'Europe/Rome', 'YYYY-MM')
        )
        ON CONFLICT (email) DO UPDATE
            SET bonus            = 0,
                last_reset_month = to_char(v_now AT TIME ZONE 'Europe/Rome', 'YYYY-MM');
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;
