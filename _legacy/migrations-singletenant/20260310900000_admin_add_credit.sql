-- ─── RPC admin_add_credit ─────────────────────────────────────────────────────
-- Aggiunge credito a un cliente in modo atomico:
--   1. Crea la riga credits se non esiste
--   2. Aggiorna balance (e free_balance se lezione gratuita)
--   3. Inserisce voce in credit_history
--   4. Auto-paga prenotazioni non pagate FIFO
--   5. Compensa eventuali debiti manuali con il credito residuo
-- security definer → bypassa RLS, ma controlla is_admin() esplicitamente.
--
-- Parametri:
--   p_email        email del cliente (chiave primaria logica)
--   p_whatsapp     telefono del cliente (opzionale)
--   p_name         nome del cliente
--   p_amount       importo (positivo = accredito, negativo = addebito)
--   p_note         nota per credit_history
--   p_method       metodo pagamento (contanti/carta/iban/lezione-gratuita/credito)
--   p_free_lesson  true = credito gratuito (non entrata)
--   p_slot_prices  JSONB con prezzi slot es. '{"personal-training":5,"small-group":10,"group-class":30}'
--
-- Ritorna JSONB: { success, new_balance, bookings_paid, total_applied, debt_offset }

CREATE OR REPLACE FUNCTION admin_add_credit(
    p_email       TEXT,
    p_whatsapp    TEXT    DEFAULT NULL,
    p_name        TEXT    DEFAULT '',
    p_amount      NUMERIC DEFAULT 0,
    p_note        TEXT    DEFAULT '',
    p_method      TEXT    DEFAULT '',
    p_free_lesson BOOLEAN DEFAULT false,
    p_slot_prices JSONB   DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_booking       RECORD;
    v_price         NUMERIC(10,2);
    v_remaining     NUMERIC(10,2);
    v_free_used     NUMERIC(10,2);
    v_pay_method    TEXT;
    v_total_applied NUMERIC(10,2) := 0;
    v_free_applied  NUMERIC(10,2) := 0;
    v_count         INTEGER       := 0;
    v_now           TIMESTAMPTZ   := now();
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_to_offset     NUMERIC(10,2);
    v_debt_offset   NUMERIC(10,2) := 0;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── 1. Trova o crea la riga credits ───────────────────────────────────────
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_email
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO credits (name, whatsapp, email, balance, free_balance)
        VALUES (p_name, p_whatsapp, v_email, 0, 0)
        RETURNING id, balance, coalesce(free_balance, 0) INTO v_credit_id, v_balance, v_free_balance;
    END IF;

    -- ── 2. Applica l'importo ──────────────────────────────────────────────────
    IF p_amount <> 0 THEN
        v_balance := round((v_balance + p_amount)::numeric, 2);
        IF p_free_lesson AND p_amount > 0 THEN
            v_free_balance := round((v_free_balance + p_amount)::numeric, 2);
        END IF;
    END IF;

    -- ── 3. Inserisce voce in credit_history ───────────────────────────────────
    INSERT INTO credit_history (credit_id, amount, note, created_at)
    VALUES (v_credit_id, p_amount, p_note, v_now);

    -- ── 4. Auto-paga prenotazioni non pagate FIFO (solo lezioni già iniziate) ──
    IF v_balance > 0 THEN
        FOR v_booking IN
            SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied
            FROM   bookings
            WHERE  lower(email) = v_email
              AND  paid = false
              AND  status NOT IN ('cancelled', 'cancellation_requested')
              AND  (
                    date < (v_now AT TIME ZONE 'Europe/Rome')::date
                    OR (date = (v_now AT TIME ZONE 'Europe/Rome')::date
                        AND split_part(time, ' - ', 1)::time <= (v_now AT TIME ZONE 'Europe/Rome')::time)
              )
            ORDER  BY date ASC, time ASC
            FOR UPDATE
        LOOP
            v_price     := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
            v_remaining := v_price - v_booking.credit_applied;

            IF v_balance >= v_remaining THEN
                -- Copertura completa: usa free_balance prima
                v_free_used    := least(v_free_balance, v_remaining);
                v_pay_method   := CASE WHEN v_free_balance >= v_remaining THEN 'lezione-gratuita' ELSE 'credito' END;
                v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
                v_free_applied := v_free_applied + v_free_used;
                v_balance      := round((v_balance - v_remaining)::numeric, 2);
                v_total_applied := v_total_applied + v_remaining;
                v_count        := v_count + 1;
                UPDATE bookings
                SET    paid = true, payment_method = v_pay_method,
                       paid_at = v_now, credit_applied = 0
                WHERE  id = v_booking.id;

            ELSIF v_balance > 0 AND v_booking.credit_applied = 0 THEN
                -- Copertura parziale (nessun credito precedente su questa prenotazione)
                v_free_used     := least(v_free_balance, v_balance);
                v_free_balance  := round((v_free_balance - v_free_used)::numeric, 2);
                v_free_applied  := v_free_applied + v_free_used;
                v_total_applied := v_total_applied + v_balance;
                UPDATE bookings SET credit_applied = v_balance WHERE id = v_booking.id;
                v_balance := 0;
            END IF;

            EXIT WHEN v_balance <= 0;
        END LOOP;

        -- Voce credit_history per auto-pagamento (solo se almeno una prenotazione pagata)
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

    -- ── 5. Compensa debiti manuali con il credito residuo ─────────────────────
    IF v_balance > 0 THEN
        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 THEN
            v_to_offset := round(least(v_debt_balance, v_balance)::numeric, 2);

            UPDATE manual_debts
            SET    balance = round((balance - v_to_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -v_to_offset,
                       'note',   'Compensato con credito',
                       'method', ''
                   ))
            WHERE  id = v_debt_id;

            v_balance     := round((v_balance - v_to_offset)::numeric, 2);
            v_debt_offset := v_to_offset;

            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '2 milliseconds');
        END IF;
    END IF;

    -- ── 6. Scrive il balance finale ───────────────────────────────────────────
    UPDATE credits
    SET    balance      = v_balance,
           free_balance = v_free_balance
    WHERE  id = v_credit_id;

    RETURN jsonb_build_object(
        'success',       true,
        'new_balance',   v_balance,
        'bookings_paid', v_count,
        'total_applied', v_total_applied,
        'debt_offset',   v_debt_offset
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_add_credit FROM public;
GRANT EXECUTE ON FUNCTION admin_add_credit TO authenticated;
