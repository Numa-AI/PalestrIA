-- ─── RPC admin_pay_bookings ───────────────────────────────────────────────────
-- Segna una lista di prenotazioni come pagate in modo atomico:
--   1. Marca ogni prenotazione in p_booking_sb_ids come pagata
--   2. Se p_manual_debt_offset > 0: riduce manual_debts.balance e aggiunge voce storico
--   3. Se metodo != 'lezione-gratuita' e p_amount_paid > 0:
--      - Calcola due_total dalla somma dei prezzi slot meno credit_applied
--      - credit_delta = p_amount_paid - due_total - p_manual_debt_offset
--      - Se credit_delta > 0: aggiunge credito e auto-paga altre prenotazioni FIFO
--      - Altrimenti: inserisce voce informativa (amount=0, display_amount=importo)
-- security definer → bypassa RLS, ma controlla is_admin() esplicitamente.
--
-- Parametri:
--   p_booking_sb_ids     array di UUID delle prenotazioni da saldare
--   p_email              email del cliente
--   p_whatsapp           telefono del cliente (opzionale)
--   p_name               nome del cliente
--   p_payment_method     metodo pagamento (contanti/carta/iban/lezione-gratuita/credito)
--   p_amount_paid        importo effettivamente ricevuto
--   p_manual_debt_offset importo del debito manuale da saldare
--   p_slot_prices        JSONB con prezzi slot
--
-- Ritorna JSONB: { success, new_balance, bookings_paid, credit_delta }

CREATE OR REPLACE FUNCTION admin_pay_bookings(
    p_booking_sb_ids     UUID[],
    p_email              TEXT,
    p_whatsapp           TEXT     DEFAULT NULL,
    p_name               TEXT     DEFAULT '',
    p_payment_method     TEXT     DEFAULT 'contanti',
    p_amount_paid        NUMERIC  DEFAULT 0,
    p_manual_debt_offset NUMERIC  DEFAULT 0,
    p_slot_prices        JSONB    DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_email         TEXT        := lower(trim(p_email));
    v_now           TIMESTAMPTZ := now();
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_due_total     NUMERIC(10,2) := 0;
    v_credit_delta  NUMERIC(10,2) := 0;
    v_booked_count  INTEGER       := 0;
    v_booking       RECORD;
    v_price         NUMERIC(10,2);
    v_remaining     NUMERIC(10,2);
    v_free_used     NUMERIC(10,2);
    v_pay_method    TEXT;
    v_total_applied NUMERIC(10,2) := 0;
    v_count         INTEGER       := 0;
    v_method_label  TEXT;
    v_sb_id         UUID;
    v_row           RECORD;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    v_method_label := CASE p_payment_method
        WHEN 'contanti' THEN 'Contanti'
        WHEN 'carta'    THEN 'Carta'
        WHEN 'iban'     THEN 'Bonifico'
        ELSE p_payment_method
    END;

    -- ── 1. Marca le prenotazioni come pagate e calcola due_total ─────────────
    FOREACH v_sb_id IN ARRAY p_booking_sb_ids
    LOOP
        SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied
        INTO   v_row
        FROM   bookings
        WHERE  id = v_sb_id
        FOR UPDATE;

        IF FOUND THEN
            v_price     := round(coalesce((p_slot_prices ->> v_row.slot_type)::numeric, 0), 2);
            v_due_total := round((v_due_total + v_price - v_row.credit_applied)::numeric, 2);

            UPDATE bookings
            SET    paid           = true,
                   payment_method = p_payment_method,
                   paid_at        = v_now,
                   credit_applied = 0
            WHERE  id = v_sb_id;

            v_booked_count := v_booked_count + 1;
        END IF;
    END LOOP;

    -- ── 2. Salda debito manuale se richiesto ──────────────────────────────────
    IF p_manual_debt_offset > 0 THEN
        SELECT id, balance
        INTO   v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_email
        FOR UPDATE;

        IF FOUND THEN
            UPDATE manual_debts
            SET    balance = round((balance - p_manual_debt_offset)::numeric, 2),
                   history = history || jsonb_build_array(jsonb_build_object(
                       'date',   v_now,
                       'amount', -p_manual_debt_offset,
                       'note',   'Saldo debito manuale',
                       'method', p_payment_method
                   ))
            WHERE  id = v_debt_id;
        END IF;
    END IF;

    -- ── 3. Gestione credito / entrata ─────────────────────────────────────────
    IF p_payment_method <> 'lezione-gratuita' AND p_amount_paid > 0 THEN

        v_credit_delta := round((p_amount_paid - v_due_total - p_manual_debt_offset)::numeric, 2);

        IF v_credit_delta > 0 THEN
            -- Acconto: aggiunge credito e auto-paga altre prenotazioni FIFO

            -- Trova o crea la riga credits
            SELECT id, balance, coalesce(free_balance, 0)
            INTO   v_credit_id, v_balance, v_free_balance
            FROM   credits
            WHERE  email = v_email
            FOR UPDATE;

            IF NOT FOUND THEN
                INSERT INTO credits (name, whatsapp, email, balance, free_balance)
                VALUES (p_name, p_whatsapp, v_email, 0, 0)
                RETURNING id, balance, coalesce(free_balance, 0)
                INTO v_credit_id, v_balance, v_free_balance;
            END IF;

            v_balance := round((v_balance + v_credit_delta)::numeric, 2);

            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, v_credit_delta,
                    'Pagamento in acconto di €' || p_amount_paid, v_now);

            -- Auto-paga altre prenotazioni non pagate FIFO
            IF v_balance > 0 THEN
                FOR v_booking IN
                    SELECT id, slot_type, coalesce(credit_applied, 0) AS credit_applied
                    FROM   bookings
                    WHERE  lower(email) = v_email
                      AND  paid = false
                      AND  status NOT IN ('cancelled', 'cancellation_requested')
                    ORDER  BY date ASC, time ASC
                    FOR UPDATE
                LOOP
                    v_price     := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);
                    v_remaining := v_price - v_booking.credit_applied;

                    IF v_balance >= v_remaining THEN
                        v_free_used    := least(v_free_balance, v_remaining);
                        v_pay_method   := CASE WHEN v_free_balance >= v_remaining THEN 'lezione-gratuita' ELSE 'credito' END;
                        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
                        v_balance      := round((v_balance - v_remaining)::numeric, 2);
                        v_total_applied := v_total_applied + v_remaining;
                        v_count        := v_count + 1;
                        UPDATE bookings
                        SET    paid = true, payment_method = v_pay_method,
                               paid_at = v_now, credit_applied = 0
                        WHERE  id = v_booking.id;

                    ELSIF v_balance > 0 AND v_booking.credit_applied = 0 THEN
                        v_free_used    := least(v_free_balance, v_balance);
                        v_free_balance := round((v_free_balance - v_free_used)::numeric, 2);
                        v_total_applied := v_total_applied + v_balance;
                        UPDATE bookings SET credit_applied = v_balance WHERE id = v_booking.id;
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

            -- Aggiorna balance finale
            UPDATE credits
            SET    balance      = v_balance,
                   free_balance = v_free_balance
            WHERE  id = v_credit_id;

        ELSE
            -- Pagamento esatto o parziale: inserisce voce informativa
            SELECT id, balance, coalesce(free_balance, 0)
            INTO   v_credit_id, v_balance, v_free_balance
            FROM   credits
            WHERE  email = v_email
            FOR UPDATE;

            IF NOT FOUND THEN
                INSERT INTO credits (name, whatsapp, email, balance, free_balance)
                VALUES (p_name, p_whatsapp, v_email, 0, 0)
                RETURNING id, balance, coalesce(free_balance, 0)
                INTO v_credit_id, v_balance, v_free_balance;
            END IF;

            INSERT INTO credit_history (credit_id, amount, display_amount, note, created_at)
            VALUES (v_credit_id, 0, p_amount_paid, v_method_label || ' ricevuto', v_now);
        END IF;

    END IF;

    RETURN jsonb_build_object(
        'success',       true,
        'new_balance',   coalesce(v_balance, 0),
        'bookings_paid', v_booked_count,
        'credit_delta',  v_credit_delta
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_pay_bookings FROM public;
GRANT EXECUTE ON FUNCTION admin_pay_bookings TO authenticated;
