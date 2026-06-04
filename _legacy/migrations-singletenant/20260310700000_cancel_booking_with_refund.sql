-- ─── CANCELLAZIONE ATOMICA CON RIMBORSO CREDITO ──────────────────────────────
-- Fix M5 dal TODO.md:
-- Cancellazione booking + rimborso credito + consumo bonus in una singola
-- transazione PostgreSQL. Previene stati parziali se il browser si chiude
-- tra un'operazione e l'altra.
--
-- Parametri:
--   p_booking_id    UUID del booking su Supabase
--   p_credit_amount Credito da rimborsare (0 = nessun rimborso)
--   p_credit_note   Nota per credit_history (es. "Rimborso annullamento 2026-03-10 10:40 - 12:00")
--   p_use_bonus     true = consuma il bonus mensile del cliente
--   p_with_bonus    true = imposta cancelled_with_bonus = true sul booking
--   p_with_penalty  true = imposta cancelled_with_penalty = true sul booking
--
-- Ritorna JSONB: { success: true } oppure { success: false, error: "..." }

CREATE OR REPLACE FUNCTION cancel_booking_with_refund(
    p_booking_id    UUID,
    p_credit_amount NUMERIC  DEFAULT 0,
    p_credit_note   TEXT     DEFAULT '',
    p_use_bonus     BOOLEAN  DEFAULT false,
    p_with_bonus    BOOLEAN  DEFAULT false,
    p_with_penalty  BOOLEAN  DEFAULT false
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking   RECORD;
    v_credit_id UUID;
    v_now       TIMESTAMPTZ := now();
BEGIN
    -- ── Leggi il booking ──────────────────────────────────────────────────────
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- ── Autorizzazione: proprietario O admin ──────────────────────────────────
    IF v_booking.user_id IS DISTINCT FROM auth.uid() AND NOT is_admin() THEN
        -- Booking anonimo (user_id IS NULL): ammesso se chiamato dal service_role
        IF v_booking.user_id IS NOT NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
        END IF;
    END IF;

    -- ── Aggiorna stato booking ────────────────────────────────────────────────
    UPDATE bookings SET
        status                    = 'cancelled',
        cancelled_at              = v_now,
        paid                      = false,
        payment_method            = null,
        credit_applied            = 0,
        cancelled_with_bonus      = p_with_bonus,
        cancelled_with_penalty    = p_with_penalty,
        cancelled_payment_method  = v_booking.payment_method,
        cancelled_paid_at         = v_booking.paid_at
    WHERE id = p_booking_id;

    -- ── Rimborso credito ──────────────────────────────────────────────────────
    IF p_credit_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        -- Trova o crea il record credits per questo cliente
        SELECT id INTO v_credit_id
        FROM credits
        WHERE email = lower(trim(v_booking.email));

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (
                v_booking.name,
                v_booking.whatsapp,
                lower(trim(v_booking.email)),
                p_credit_amount,
                0
            )
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET balance = round((balance + p_credit_amount)::numeric, 2)
            WHERE id = v_credit_id;
        END IF;

        -- Inserisce voce in credit_history
        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, p_credit_amount, p_credit_note, v_now);
    END IF;

    -- ── Consumo bonus mensile ─────────────────────────────────────────────────
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

-- Accessibile a utenti autenticati e service_role (pg_cron)
REVOKE ALL ON FUNCTION cancel_booking_with_refund FROM public;
GRANT EXECUTE ON FUNCTION cancel_booking_with_refund TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_booking_with_refund TO service_role;
