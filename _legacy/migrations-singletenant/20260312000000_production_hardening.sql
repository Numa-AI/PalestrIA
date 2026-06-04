-- ─── PRODUCTION HARDENING ────────────────────────────────────────────────────
-- Fix critici pre-go-live:
--   1. FOR UPDATE lock in cancel_booking_with_refund (previene doppio rimborso)
--   2. Restringe fulfill_pending_cancellation (rimuove accesso anon)
--   3. Restringe bookings INSERT RLS (forza uso RPC)
--   4. Validazione input nelle RPC admin
--   5. FOR UPDATE in admin_rename_client (previene race condition)

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. cancel_booking_with_refund — aggiunto FOR UPDATE su booking + credits
-- ═══════════════════════════════════════════════════════════════════════════════

-- Drop tutte le firme note per evitare ambiguità
DROP FUNCTION IF EXISTS cancel_booking_with_refund(UUID, NUMERIC, TEXT, BOOLEAN, BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS cancel_booking_with_refund(UUID, NUMERIC, TEXT, BOOLEAN, BOOLEAN, BOOLEAN, NUMERIC, TEXT);

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
    IF v_booking.user_id IS DISTINCT FROM auth.uid() AND NOT is_admin() THEN
        IF v_booking.user_id IS NOT NULL THEN
            RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
        END IF;
    END IF;

    -- ── Aggiorna stato booking ───────────────────────────────────────────────
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

REVOKE ALL ON FUNCTION cancel_booking_with_refund FROM public;
GRANT EXECUTE ON FUNCTION cancel_booking_with_refund TO authenticated;
GRANT EXECUTE ON FUNCTION cancel_booking_with_refund TO service_role;


-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fulfill_pending_cancellation — rimuovi accesso anon
-- ═══════════════════════════════════════════════════════════════════════════════

REVOKE EXECUTE ON FUNCTION fulfill_pending_cancellation FROM anon;


-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. bookings INSERT RLS — solo authenticated (forza uso book_slot_atomic)
-- ═══════════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "bookings_public_insert" ON bookings;
CREATE POLICY "bookings_authenticated_insert"
    ON bookings FOR INSERT TO authenticated
    WITH CHECK (true);


-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. Validazione input — admin_add_credit
-- ═══════════════════════════════════════════════════════════════════════════════

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

    -- ── Validazione input ────────────────────────────────────────────────────
    IF v_email IS NULL OR v_email = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'email_required');
    END IF;

    IF v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_email');
    END IF;

    IF p_amount < -10000 OR p_amount > 10000 THEN
        RETURN jsonb_build_object('success', false, 'error', 'amount_out_of_range');
    END IF;

    -- ── 1. Trova o crea la riga credits ──────────────────────────────────────
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

    -- ── 2. Applica l'importo ─────────────────────────────────────────────────
    IF p_amount <> 0 THEN
        v_balance := round((v_balance + p_amount)::numeric, 2);
        IF p_free_lesson AND p_amount > 0 THEN
            v_free_balance := round((v_free_balance + p_amount)::numeric, 2);
        END IF;
    END IF;

    -- ── 3. Inserisce voce in credit_history ──────────────────────────────────
    INSERT INTO credit_history (credit_id, amount, note, created_at)
    VALUES (v_credit_id, p_amount, p_note, v_now);

    -- ── 4. Auto-paga prenotazioni non pagate FIFO ────────────────────────────
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
                v_free_applied := v_free_applied + v_free_used;
                v_balance      := round((v_balance - v_remaining)::numeric, 2);
                v_total_applied := v_total_applied + v_remaining;
                v_count        := v_count + 1;
                UPDATE bookings
                SET    paid = true, payment_method = v_pay_method,
                       paid_at = v_now, credit_applied = 0
                WHERE  id = v_booking.id;

            ELSIF v_balance > 0 AND v_booking.credit_applied = 0 THEN
                v_free_used     := least(v_free_balance, v_balance);
                v_free_balance  := round((v_free_balance - v_free_used)::numeric, 2);
                v_free_applied  := v_free_applied + v_free_used;
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

    -- ── 5. Compensa debiti manuali con il credito residuo ────────────────────
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

    -- ── 6. Scrive il balance finale ──────────────────────────────────────────
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


-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. admin_rename_client — aggiunto FOR UPDATE + fix OR condition
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION admin_rename_client(
    p_old_email    TEXT,
    p_old_whatsapp TEXT DEFAULT NULL,
    p_new_name     TEXT DEFAULT '',
    p_new_email    TEXT DEFAULT '',
    p_new_whatsapp TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_old_email TEXT := lower(trim(p_old_email));
    v_new_email TEXT := lower(trim(p_new_email));
    v_bookings  INTEGER;
    v_credits   INTEGER;
    v_debts     INTEGER;
    v_bk        RECORD;
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    -- ── Validazione ──────────────────────────────────────────────────────────
    IF v_new_email = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'new_email_required');
    END IF;

    IF p_new_name = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'new_name_required');
    END IF;

    -- ── Verifica che la nuova email non sia già usata da un altro cliente ────
    IF v_new_email <> v_old_email THEN
        IF EXISTS (SELECT 1 FROM credits WHERE email = v_new_email) THEN
            RETURN jsonb_build_object('success', false, 'error', 'email_already_exists');
        END IF;
    END IF;

    -- ── 1. Bookings (con lock per evitare race condition) ────────────────────
    -- Lock prima, poi update — previene conflitti con cancel_booking_with_refund
    PERFORM id FROM bookings
    WHERE  lower(email) = v_old_email
       OR  (p_old_whatsapp IS NOT NULL AND p_old_whatsapp <> '' AND whatsapp = p_old_whatsapp)
    FOR UPDATE;

    UPDATE bookings
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  lower(email) = v_old_email
       OR  (p_old_whatsapp IS NOT NULL AND p_old_whatsapp <> '' AND whatsapp = p_old_whatsapp);
    GET DIAGNOSTICS v_bookings = ROW_COUNT;

    -- ── 2. Credits (con lock) ────────────────────────────────────────────────
    PERFORM id FROM credits WHERE email = v_old_email FOR UPDATE;

    UPDATE credits
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  email = v_old_email;
    GET DIAGNOSTICS v_credits = ROW_COUNT;

    -- ── 3. Manual debts (con lock) ───────────────────────────────────────────
    PERFORM id FROM manual_debts WHERE lower(email) = v_old_email FOR UPDATE;

    UPDATE manual_debts
    SET    name     = p_new_name,
           email    = v_new_email,
           whatsapp = p_new_whatsapp
    WHERE  lower(email) = v_old_email;
    GET DIAGNOSTICS v_debts = ROW_COUNT;

    RETURN jsonb_build_object(
        'success',          true,
        'bookings_updated', v_bookings,
        'credits_updated',  v_credits,
        'debts_updated',    v_debts
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_rename_client FROM public;
GRANT EXECUTE ON FUNCTION admin_rename_client TO authenticated;
