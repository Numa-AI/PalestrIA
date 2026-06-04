-- ─── RPC admin_delete_booking_with_refund ────────────────────────────────────
-- Elimina permanentemente un booking (non cancellation, ma DELETE) e
-- rimborsa il credito se era stato pagato. Operazione atomica.
--
-- Parametri:
--   p_booking_id  UUID del booking su Supabase
--   p_slot_prices JSONB con prezzi slot (per calcolare il rimborso)
--
-- Ritorna JSONB: { success, credit_refunded }

CREATE OR REPLACE FUNCTION admin_delete_booking_with_refund(
    p_booking_id  UUID,
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
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── Leggi il booking ────────────────────────────────────────────────────
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- ── Rimborso credito se era pagato ──────────────────────────────────────
    IF v_booking.paid THEN
        v_refund_amount := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
    END IF;

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
                'Rimborso lezione ' || v_booking.date::text,
                v_now);
    END IF;

    -- ── Elimina il booking ──────────────────────────────────────────────────
    DELETE FROM bookings WHERE id = p_booking_id;

    RETURN jsonb_build_object(
        'success',         true,
        'credit_refunded', v_refund_amount
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_delete_booking_with_refund FROM public;
GRANT EXECUTE ON FUNCTION admin_delete_booking_with_refund TO authenticated;
