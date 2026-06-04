-- ─── Fix: admin_pay_bookings NON auto-paga prenotazioni non selezionate ──────
-- Prima: se l'importo pagato superava il dovuto, il credito in eccesso veniva
-- usato per auto-pagare FIFO tutte le prenotazioni non pagate (anche future).
-- Ora: il credito in eccesso resta come saldo credito senza toccare altre
-- prenotazioni. L'admin decide esplicitamente cosa pagare.

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
    v_price         NUMERIC(10,2);
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

    -- ── 1. Marca le prenotazioni selezionate come pagate e calcola due_total ──
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

    -- ── 3. Gestione credito ───────────────────────────────────────────────────
    IF p_payment_method <> 'lezione-gratuita' AND p_amount_paid > 0 THEN

        v_credit_delta := round((p_amount_paid - v_due_total - p_manual_debt_offset)::numeric, 2);

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

        IF v_credit_delta > 0 THEN
            -- Credito in eccesso: salva come saldo (NO auto-pay di altre prenotazioni)
            v_balance := round((v_balance + v_credit_delta)::numeric, 2);

            INSERT INTO credit_history (credit_id, amount, display_amount, note, created_at, method)
            VALUES (v_credit_id, v_credit_delta, p_amount_paid,
                    'Pagamento in acconto di €' || p_amount_paid, v_now, p_payment_method);

            UPDATE credits
            SET    balance      = v_balance,
                   free_balance = v_free_balance
            WHERE  id = v_credit_id;
        ELSE
            -- Pagamento esatto o parziale: inserisce voce informativa
            INSERT INTO credit_history (credit_id, amount, display_amount, note, created_at, method)
            VALUES (v_credit_id, 0, p_amount_paid, v_method_label || ' ricevuto', v_now, p_payment_method);
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
