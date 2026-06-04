-- ─── RPC apply_credit_on_booking ─────────────────────────────────────────────
-- Applica il credito disponibile a una prenotazione in modo atomico:
--   1. Recupera la prenotazione; se non trovata o già pagata → esce
--   2. Recupera saldo credits per lower(p_email)
--   3. Recupera saldo manual_debts per lower(p_email)
--   4. net_credit = max(0, credits_balance - manual_debts_balance)
--   5. Recupera il prezzo slot da p_slot_prices
--   6. Se net_credit <= 0 → {success:true, paid:false, credit_applied:0}
--   7. Se net_credit >= price → pagamento completo (usa free_balance prima)
--      + loop FIFO su altre prenotazioni non pagate
--   8. Se 0 < net_credit < price → credito parziale (credit_applied)
-- Nessun controllo admin: chiamata dai clienti.
--
-- Parametri:
--   p_booking_id  UUID della prenotazione
--   p_email       email del cliente
--   p_slot_prices JSONB con prezzi slot
--
-- Ritorna JSONB: { success, paid, credit_applied, new_balance }

CREATE OR REPLACE FUNCTION apply_credit_on_booking(
    p_booking_id  UUID,
    p_email       TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_booking       RECORD;
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_balance  NUMERIC(10,2) := 0;
    v_net_credit    NUMERIC(10,2);
    v_price         NUMERIC(10,2);
    v_method        TEXT;
    v_free_used     NUMERIC(10,2);
    v_other         RECORD;
    v_other_price   NUMERIC(10,2);
    v_other_remain  NUMERIC(10,2);
    v_other_free    NUMERIC(10,2);
    v_other_method  TEXT;
    v_total_applied NUMERIC(10,2) := 0;
    v_count         INTEGER       := 0;
BEGIN
    -- ── 1. Recupera la prenotazione ───────────────────────────────────────────
    SELECT id, slot_type, paid, lower(email) AS v_email_bk
    INTO   v_booking
    FROM   bookings
    WHERE  id = p_booking_id
    FOR UPDATE;

    IF NOT FOUND OR v_booking.paid THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', 0);
    END IF;

    -- ── 2. Recupera saldo credits ─────────────────────────────────────────────
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', 0);
    END IF;

    -- ── 3. Recupera saldo manual_debts ────────────────────────────────────────
    SELECT coalesce(balance, 0)
    INTO   v_debt_balance
    FROM   manual_debts
    WHERE  lower(email) = v_email;

    -- ── 4. net_credit = max(0, credits_balance - manual_debts_balance) ────────
    v_net_credit := round(greatest(0, v_balance - v_debt_balance)::numeric, 2);

    -- ── 5. Prezzo slot ────────────────────────────────────────────────────────
    v_price := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);

    -- ── 6. Nessun credito netto disponibile ───────────────────────────────────
    IF v_net_credit <= 0 THEN
        RETURN jsonb_build_object('success', true, 'paid', false, 'credit_applied', 0, 'new_balance', v_balance);
    END IF;

    -- ── 7. Credito sufficiente per coprire il prezzo intero ───────────────────
    IF v_net_credit >= v_price THEN
        -- Usa free_balance prima
        v_method       := CASE WHEN v_free_balance >= v_price THEN 'lezione-gratuita' ELSE 'credito' END;
        v_free_used    := least(v_free_balance, v_price);
        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
        v_balance      := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    paid           = true,
               payment_method = v_method,
               paid_at        = v_now,
               credit_applied = 0
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_price,
            'Lezione ' || v_booking.slot_type || ' — pagata con ' ||
                CASE v_method WHEN 'lezione-gratuita' THEN 'lezione gratuita' ELSE 'credito' END,
            v_now
        );

        -- Auto-paga altre prenotazioni non pagate FIFO se rimane credito
        IF v_balance > 0 THEN
            FOR v_other IN
                SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied
                FROM   bookings
                WHERE  lower(email) = v_email
                  AND  paid = false
                  AND  id <> p_booking_id
                  AND  status NOT IN ('cancelled', 'cancellation_requested')
                ORDER  BY date ASC, time ASC
                FOR UPDATE
            LOOP
                v_other_price  := round(coalesce((p_slot_prices ->> v_other.slot_type)::numeric, 0), 2);
                v_other_remain := v_other_price - v_other.credit_applied;

                IF v_balance >= v_other_remain THEN
                    v_other_free   := least(v_free_balance, v_other_remain);
                    v_other_method := CASE WHEN v_free_balance >= v_other_remain THEN 'lezione-gratuita' ELSE 'credito' END;
                    v_free_balance := round((v_free_balance - v_other_free)::numeric, 2);
                    v_balance      := round((v_balance - v_other_remain)::numeric, 2);
                    v_total_applied := v_total_applied + v_other_remain;
                    v_count        := v_count + 1;
                    UPDATE bookings
                    SET    paid = true, payment_method = v_other_method,
                           paid_at = v_now, credit_applied = 0
                    WHERE  id = v_other.id;

                ELSIF v_balance > 0 AND v_other.credit_applied = 0 THEN
                    v_other_free   := least(v_free_balance, v_balance);
                    v_free_balance := round((v_free_balance - v_other_free)::numeric, 2);
                    v_total_applied := v_total_applied + v_balance;
                    UPDATE bookings SET credit_applied = v_balance WHERE id = v_other.id;
                    v_balance := 0;
                END IF;

                EXIT WHEN v_balance <= 0;
            END LOOP;

            IF v_count > 0 THEN
                INSERT INTO credit_history (credit_id, amount, note, created_at)
                VALUES (
                    v_credit_id,
                    -v_total_applied,
                    'Auto-pagamento ' || v_count || ' lezione' || CASE WHEN v_count > 1 THEN 'i' ELSE '' END || ' con credito',
                    v_now + interval '1 millisecond'
                );
            END IF;
        END IF;

        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        RETURN jsonb_build_object(
            'success',        true,
            'paid',           true,
            'credit_applied', 0,
            'new_balance',    v_balance
        );

    -- ── 8. Credito parziale ───────────────────────────────────────────────────
    ELSE
        v_free_used    := least(v_free_balance, v_net_credit);
        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
        v_balance      := round((v_balance - v_net_credit)::numeric, 2);

        UPDATE bookings
        SET    credit_applied = v_net_credit
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_net_credit,
            'Credito parziale lezione ' || v_booking.slot_type,
            v_now
        );

        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        RETURN jsonb_build_object(
            'success',        true,
            'paid',           false,
            'credit_applied', v_net_credit,
            'new_balance',    v_balance
        );
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION apply_credit_on_booking FROM public;
GRANT EXECUTE ON FUNCTION apply_credit_on_booking TO anon;
GRANT EXECUTE ON FUNCTION apply_credit_on_booking TO authenticated;
GRANT EXECUTE ON FUNCTION apply_credit_on_booking TO service_role;
