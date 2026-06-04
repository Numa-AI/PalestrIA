-- ─── RPC fulfill_pending_cancellation ────────────────────────────────────────
-- Quando arriva una nuova prenotazione, cancella la prima richiesta pendente
-- per quello slot (FIFO) e rimborsa il credito se era stata pagata.
-- Chiamata dalla logica di booking lato client dopo una nuova prenotazione.
--
-- NON richiede admin: qualsiasi utente (o anon) può triggerare il fulfill.
--
-- Parametri:
--   p_date        data dello slot (YYYY-MM-DD)
--   p_time        orario dello slot (es. "10:40 - 12:00")
--   p_slot_prices JSONB prezzi slot
--
-- Ritorna JSONB: { success, found, booking_id, credit_refunded }

CREATE OR REPLACE FUNCTION fulfill_pending_cancellation(
    p_date        TEXT,
    p_time        TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking        RECORD;
    v_credit_id      UUID;
    v_refund_amount  NUMERIC(10,2) := 0;
    v_now            TIMESTAMPTZ := now();
BEGIN
    -- ── Trova la prima richiesta pendente FIFO ──────────────────────────────
    SELECT * INTO v_booking
    FROM   bookings
    WHERE  date::text = p_date
      AND  time       = p_time
      AND  (status = 'cancellation_requested'
            OR (status = 'confirmed' AND cancellation_requested_at IS NOT NULL))
    ORDER  BY cancellation_requested_at ASC NULLS LAST
    LIMIT  1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'found', false);
    END IF;

    -- ── Calcola rimborso ────────────────────────────────────────────────────
    IF v_booking.paid OR coalesce(v_booking.credit_applied, 0) > 0 THEN
        v_refund_amount := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
    END IF;

    -- ── Aggiorna il booking: cancella ────────────────────────────────────────
    UPDATE bookings SET
        status                   = 'cancelled',
        cancelled_at             = v_now,
        cancelled_payment_method = v_booking.payment_method,
        cancelled_paid_at        = v_booking.paid_at,
        paid                     = false,
        payment_method           = null,
        paid_at                  = null,
        credit_applied           = 0
    WHERE id = v_booking.id;

    -- ── Rimborso credito ────────────────────────────────────────────────────
    IF v_refund_amount > 0
       AND v_booking.email IS NOT NULL
       AND trim(v_booking.email) <> '' THEN

        SELECT id INTO v_credit_id
        FROM   credits
        WHERE  email = lower(trim(v_booking.email))
        FOR UPDATE;

        IF NOT FOUND THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, lower(trim(v_booking.email)), v_refund_amount, 0)
            RETURNING id INTO v_credit_id;
        ELSE
            UPDATE credits
            SET    balance = round((balance + v_refund_amount)::numeric, 2)
            WHERE  id = v_credit_id;
        END IF;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_refund_amount,
                'Rimborso lezione ' || p_date || ' (annullamento soddisfatto)',
                v_now);
    END IF;

    RETURN jsonb_build_object(
        'success',         true,
        'found',           true,
        'booking_id',      v_booking.id,
        'credit_refunded', v_refund_amount
    );
END;
$$;

REVOKE ALL ON FUNCTION fulfill_pending_cancellation FROM public;
GRANT EXECUTE ON FUNCTION fulfill_pending_cancellation TO anon;
GRANT EXECUTE ON FUNCTION fulfill_pending_cancellation TO authenticated;
GRANT EXECUTE ON FUNCTION fulfill_pending_cancellation TO service_role;
