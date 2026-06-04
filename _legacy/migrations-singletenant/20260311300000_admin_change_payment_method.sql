-- ─── RPC admin_change_payment_method ─────────────────────────────────────────
-- Gestisce tutti gli scenari di cambio metodo pagamento in modo atomico.
-- security definer → bypassa RLS, ma controlla is_admin() esplicitamente.
--
-- Scenari gestiti:
--   A: old_paid=T, old_method='credito', new_paid=F          → rimborso credito
--   B: old_paid=F, new_paid=T, new_method='credito'          → addebito credito
--   C: old_paid=T, old_method='credito', new_method!='credito' → rimborso + nuovo metodo
--   D: old_paid=T, old_method non-credito, new_method='credito' → nascondi vecchia voce + addebito
--   E: old_paid=T, old_method='lezione-gratuita', new_method='credito' → addebito (nessuna voce da nascondere)
--   F: old_paid=F, new_paid=T, new_method non-credito       → registra entrata
--   G: old_paid=T, old_method non-credito, new_paid=F       → nascondi voce entrata
--   H: tutto il resto                                        → aggiorna solo booking
--
-- Parametri:
--   p_booking_id   UUID della prenotazione
--   p_new_paid     nuovo stato pagato
--   p_new_method   nuovo metodo pagamento
--   p_new_paid_at  data/ora pagamento (opzionale)
--   p_slot_prices  JSONB con prezzi slot
--
-- Ritorna JSONB: { success, new_balance }

CREATE OR REPLACE FUNCTION admin_change_payment_method(
    p_booking_id   UUID,
    p_new_paid     BOOLEAN,
    p_new_method   TEXT,
    p_new_paid_at  TIMESTAMPTZ DEFAULT NULL,
    p_slot_prices  JSONB DEFAULT '{"personal-training":5,"small-group":10,"group-class":30}'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking       RECORD;
    v_now           TIMESTAMPTZ   := now();
    v_credit_id     UUID;
    v_balance       NUMERIC(10,2);
    v_free_balance  NUMERIC(10,2);
    v_price         NUMERIC(10,2);
    v_method_label  TEXT;
    v_debt_id       UUID;
    v_debt_balance  NUMERIC(10,2);
    v_to_offset     NUMERIC(10,2);
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── 1. Recupera la prenotazione ───────────────────────────────────────────
    SELECT id,
           paid              AS old_paid,
           payment_method    AS old_method,
           slot_type,
           lower(email)      AS v_email,
           whatsapp,
           name,
           date,
           time
    INTO   v_booking
    FROM   bookings
    WHERE  id = p_booking_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- ── 2. Prezzo slot e label metodo ─────────────────────────────────────────
    v_price := round(coalesce((p_slot_prices ->> v_booking.slot_type)::numeric, 0), 2);

    v_method_label := CASE p_new_method
        WHEN 'contanti' THEN 'Contanti'
        WHEN 'carta'    THEN 'Carta'
        WHEN 'iban'     THEN 'Bonifico'
        ELSE p_new_method
    END;

    -- ── 3. Recupera riga credits (se necessario) ──────────────────────────────
    SELECT id, balance, coalesce(free_balance, 0)
    INTO   v_credit_id, v_balance, v_free_balance
    FROM   credits
    WHERE  email = v_booking.v_email
    FOR UPDATE;

    -- ── 4. Branching scenari ──────────────────────────────────────────────────

    IF v_booking.old_paid AND v_booking.old_method = 'credito' AND NOT p_new_paid THEN
        -- ── Caso A: pagato con credito → non pagato: rimborso ─────────────────
        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        v_balance := round((v_balance + v_price)::numeric, 2);

        UPDATE bookings
        SET    paid = false, payment_method = null, paid_at = null, credit_applied = 0
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_price,
                'Rimborso modifica pagamento ' || v_booking.date || ' ' || v_booking.time, v_now);

        -- Compensazione debito manuale con il credito rimborsato
        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_booking.v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 AND v_balance > 0 THEN
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
            v_balance := round((v_balance - v_to_offset)::numeric, 2);
            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '1 millisecond');
        END IF;

    ELSIF NOT v_booking.old_paid AND p_new_paid AND p_new_method = 'credito' THEN
        -- ── Caso B: non pagato → pagato con credito: addebito ─────────────────
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    paid = true, payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Pagamento lezione ' || v_booking.date || ' ' || v_booking.time || ' con credito', v_now);

    ELSIF v_booking.old_paid AND v_booking.old_method = 'credito'
          AND p_new_paid AND p_new_method <> 'credito' THEN
        -- ── Caso C: credito → altro metodo: rimborso + registra entrata ────────
        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        v_balance := round((v_balance + v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, v_price,
                'Cambio metodo da credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

        -- Compensazione debito manuale
        SELECT id, balance INTO v_debt_id, v_debt_balance
        FROM   manual_debts
        WHERE  lower(email) = v_booking.v_email
        FOR UPDATE;

        IF FOUND AND v_debt_balance > 0 AND v_balance > 0 THEN
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
            v_balance := round((v_balance - v_to_offset)::numeric, 2);
            INSERT INTO credit_history (credit_id, amount, note, created_at)
            VALUES (v_credit_id, -v_to_offset, 'Applicato a debito manuale',
                    v_now + interval '1 millisecond');
        END IF;

        IF p_new_method NOT IN ('lezione-gratuita', 'credito') THEN
            INSERT INTO credit_history (credit_id, amount, display_amount, booking_ref, note, created_at)
            VALUES (v_credit_id, 0, v_price, p_booking_id, v_method_label || ' ricevuto',
                    v_now + interval '2 milliseconds');
        END IF;

    ELSIF v_booking.old_paid
          AND coalesce(v_booking.old_method, '') NOT IN ('credito', 'lezione-gratuita')
          AND p_new_paid AND p_new_method = 'credito' THEN
        -- ── Caso D: contanti/carta/iban → credito: nascondi vecchia voce + addebito
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        -- Nascondi la vecchia voce informativa (amount=0)
        IF v_credit_id IS NOT NULL THEN
            UPDATE credit_history
            SET    hidden = true
            WHERE  credit_id = v_credit_id
              AND  booking_ref = p_booking_id
              AND  amount = 0;
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Cambio metodo a credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

    ELSIF v_booking.old_paid AND v_booking.old_method = 'lezione-gratuita'
          AND p_new_paid AND p_new_method = 'credito' THEN
        -- ── Caso E: lezione gratuita → credito: addebito (nessuna voce da nascondere)
        IF v_credit_id IS NULL OR v_balance < v_price THEN
            RETURN jsonb_build_object(
                'success', false,
                'error',   'insufficient_credit',
                'balance', coalesce(v_balance, 0)
            );
        END IF;

        v_balance := round((v_balance - v_price)::numeric, 2);

        UPDATE bookings
        SET    payment_method = 'credito',
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        INSERT INTO credit_history (credit_id, amount, note, created_at)
        VALUES (v_credit_id, -v_price,
                'Cambio metodo a credito — lezione ' || v_booking.date || ' ' || v_booking.time, v_now);

    ELSIF NOT v_booking.old_paid AND p_new_paid
          AND p_new_method NOT IN ('credito', 'lezione-gratuita') THEN
        -- ── Caso F: non pagato → pagato (contanti/carta/iban): registra entrata ─
        UPDATE bookings
        SET    paid = true, payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

        IF v_credit_id IS NULL THEN
            INSERT INTO credits (name, whatsapp, email, balance, free_balance)
            VALUES (v_booking.name, v_booking.whatsapp, v_booking.v_email, 0, 0)
            RETURNING id, balance, coalesce(free_balance, 0)
            INTO v_credit_id, v_balance, v_free_balance;
        END IF;

        INSERT INTO credit_history (credit_id, amount, display_amount, booking_ref, note, created_at)
        VALUES (v_credit_id, 0, v_price, p_booking_id, v_method_label || ' ricevuto', v_now);

    ELSIF v_booking.old_paid
          AND coalesce(v_booking.old_method, '') NOT IN ('credito', 'lezione-gratuita')
          AND NOT p_new_paid THEN
        -- ── Caso G: pagato (contanti/carta/iban) → non pagato: nascondi voce ───
        UPDATE bookings
        SET    paid = false, payment_method = null, paid_at = null, credit_applied = 0
        WHERE  id = p_booking_id;

        IF v_credit_id IS NOT NULL THEN
            UPDATE credit_history
            SET    hidden = true
            WHERE  credit_id = v_credit_id
              AND  booking_ref = p_booking_id
              AND  amount = 0;
        END IF;

    ELSE
        -- ── Caso H: nessuna variazione credito, aggiorna solo booking ──────────
        UPDATE bookings
        SET    paid = p_new_paid,
               payment_method = p_new_method,
               paid_at = coalesce(p_new_paid_at, v_now)
        WHERE  id = p_booking_id;

    END IF;

    -- ── 5. Scrive il balance finale se la riga credits è stata toccata ────────
    IF v_credit_id IS NOT NULL THEN
        UPDATE credits
        SET    balance      = v_balance,
               free_balance = v_free_balance
        WHERE  id = v_credit_id;
    END IF;

    RETURN jsonb_build_object(
        'success',     true,
        'new_balance', coalesce(v_balance, 0)
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_change_payment_method FROM public;
GRANT EXECUTE ON FUNCTION admin_change_payment_method TO authenticated;
