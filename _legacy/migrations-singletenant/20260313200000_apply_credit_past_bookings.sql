-- ─── RPC apply_credit_to_past_bookings ────────────────────────────────────────
-- Applica il credito disponibile SOLO alle prenotazioni la cui ora di inizio
-- è già passata (lezione iniziata). Chiamata dal client al caricamento pagina
-- e/o da pg_cron ogni minuto.
--
-- Logica:
--   1. Trova tutte le prenotazioni non pagate, confirmed, con ora inizio <= now
--   2. Per ciascuna, applica il credito netto (credits - manual_debts) FIFO
--   3. Aggiorna credits.balance e credit_history
--
-- Parametri:
--   p_email       email del cliente
--   p_slot_prices JSONB con prezzi slot
--
-- Ritorna JSONB: { success, bookings_paid, total_applied }

CREATE OR REPLACE FUNCTION apply_credit_to_past_bookings(
    p_email       TEXT,
    p_slot_prices JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_now_rome      TIMESTAMP   := (v_now AT TIME ZONE 'Europe/Rome');
    v_today         DATE        := v_now_rome::date;
    v_current_time  TIME        := v_now_rome::time;
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_balance  NUMERIC(10,2) := 0;
    v_net_credit    NUMERIC(10,2);
    v_booking       RECORD;
    v_price         NUMERIC(10,2);
    v_remain        NUMERIC(10,2);
    v_method        TEXT;
    v_free_used     NUMERIC(10,2);
    v_count         INTEGER       := 0;
    v_total_applied NUMERIC(10,2) := 0;
    v_start_time    TIME;
BEGIN
    -- ── 1. Recupera saldo credits ───────────────────────────────────────────
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND OR v_balance <= 0 THEN
        RETURN jsonb_build_object('success', true, 'bookings_paid', 0, 'total_applied', 0);
    END IF;

    -- ── 2. Recupera saldo manual_debts ──────────────────────────────────────
    SELECT coalesce(balance, 0)
    INTO   v_debt_balance
    FROM   manual_debts
    WHERE  lower(email) = v_email;

    -- ── 3. net_credit ───────────────────────────────────────────────────────
    v_net_credit := round(greatest(0, v_balance - v_debt_balance)::numeric, 2);

    IF v_net_credit <= 0 THEN
        RETURN jsonb_build_object('success', true, 'bookings_paid', 0, 'total_applied', 0);
    END IF;

    -- ── 4. Loop su prenotazioni passate non pagate ──────────────────────────
    FOR v_booking IN
        SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied, date, time
        FROM   bookings
        WHERE  lower(email) = v_email
          AND  paid = false
          AND  status = 'confirmed'
          AND  (
                date < v_today
                OR (date = v_today AND split_part(time, ' - ', 1)::time <= v_current_time)
          )
        ORDER  BY date ASC, time ASC
        FOR UPDATE
    LOOP
        v_price  := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
        v_remain := v_price - v_booking.credit_applied;

        IF v_remain <= 0 THEN CONTINUE; END IF;

        IF v_net_credit >= v_remain THEN
            -- Pagamento completo
            v_free_used    := least(v_free_balance, v_remain);
            v_method       := CASE WHEN v_free_balance >= v_remain THEN 'lezione-gratuita' ELSE 'credito' END;
            v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
            v_balance      := round((v_balance - v_remain)::numeric, 2);
            v_net_credit   := round((v_net_credit - v_remain)::numeric, 2);
            v_total_applied := v_total_applied + v_remain;
            v_count        := v_count + 1;

            UPDATE bookings
            SET    paid           = true,
                   payment_method = v_method,
                   paid_at        = v_now,
                   credit_applied = 0
            WHERE  id = v_booking.id;

        ELSIF v_net_credit > 0 AND v_booking.credit_applied = 0 THEN
            -- Credito parziale
            v_free_used    := least(v_free_balance, v_net_credit);
            v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
            v_total_applied := v_total_applied + v_net_credit;
            UPDATE bookings SET credit_applied = v_net_credit WHERE id = v_booking.id;
            v_balance    := round((v_balance - v_net_credit)::numeric, 2);
            v_net_credit := 0;
        END IF;

        EXIT WHEN v_net_credit <= 0;
    END LOOP;

    -- ── 5. Aggiorna credits e history ───────────────────────────────────────
    IF v_total_applied > 0 THEN
        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (
            v_credit_id,
            -v_total_applied,
            CASE WHEN v_count = 1
                THEN 'Pagamento automatico lezione con credito'
                ELSE 'Pagamento automatico ' || v_count || ' lezioni con credito'
            END,
            v_now
        );
    END IF;

    RETURN jsonb_build_object(
        'success',        true,
        'bookings_paid',  v_count,
        'total_applied',  v_total_applied,
        'new_balance',    v_balance
    );
END;
$$;

REVOKE ALL ON FUNCTION apply_credit_to_past_bookings FROM public;
GRANT EXECUTE ON FUNCTION apply_credit_to_past_bookings TO anon;
GRANT EXECUTE ON FUNCTION apply_credit_to_past_bookings TO authenticated;
GRANT EXECUTE ON FUNCTION apply_credit_to_past_bookings TO service_role;
