-- ─── Traccia chi ha creato/annullato un booking (admin vs utente) ─────────────
-- created_by:   auth.uid() di chi ha creato il booking
-- cancelled_by: auth.uid() di chi ha annullato il booking
-- Nullable: le righe esistenti restano NULL (= sconosciuto).

ALTER TABLE bookings ADD COLUMN IF NOT EXISTS created_by   UUID;
ALTER TABLE bookings ADD COLUMN IF NOT EXISTS cancelled_by UUID;

-- ─── book_slot_atomic: aggiunge created_by = auth.uid() ──────────────────────
-- Copia esatta della versione 20260324300000_admin_bypass_too_late.sql
-- con l'unica aggiunta di created_by nell'INSERT.

CREATE OR REPLACE FUNCTION book_slot_atomic(
    p_local_id      TEXT,
    p_user_id       UUID,
    p_date          TEXT,
    p_time          TEXT,
    p_slot_type     TEXT,
    p_max_capacity  INTEGER,
    p_name          TEXT,
    p_email         TEXT,
    p_whatsapp      TEXT,
    p_notes         TEXT,
    p_created_at    TIMESTAMPTZ,
    p_date_display  TEXT DEFAULT ''
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_count      INTEGER;
    v_id         UUID;
    v_start_time TIME;
    v_lesson_dt  TIMESTAMPTZ;
BEGIN
    -- ── Validazioni input ────────────────────────────────────────────────────
    IF p_email IS NOT NULL AND p_email <> '' AND
       p_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_email');
    END IF;

    IF p_date::DATE < current_date AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'past_date');
    END IF;

    IF p_name IS NULL OR trim(p_name) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing_name');
    END IF;

    IF p_max_capacity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_capacity');
    END IF;

    -- ── Blocca se sono passati più di 30 min dall'inizio lezione ────────────
    -- Admin bypassa questo check
    IF NOT is_admin() THEN
        v_start_time := split_part(p_time, ' - ', 1)::TIME;
        v_lesson_dt  := (p_date::DATE + v_start_time) AT TIME ZONE 'Europe/Rome';

        IF now() > v_lesson_dt + interval '30 minutes' THEN
            RETURN jsonb_build_object('success', false, 'error', 'too_late');
        END IF;
    END IF;

    -- ── Advisory lock su (data, orario, tipo) ────────────────────────────────
    PERFORM pg_advisory_xact_lock(hashtext(p_date || '|' || p_time || '|' || p_slot_type));

    -- Conta prenotazioni attive per questo slot
    SELECT COUNT(*) INTO v_count
    FROM bookings
    WHERE date      = p_date::DATE
      AND time      = p_time
      AND slot_type = p_slot_type
      AND status IN ('confirmed', 'cancellation_requested');

    IF v_count >= p_max_capacity THEN
        RETURN jsonb_build_object('success', false, 'error', 'slot_full');
    END IF;

    INSERT INTO bookings (
        local_id, user_id, date, time, slot_type,
        name, email, whatsapp, notes, status, created_at, date_display,
        created_by
    ) VALUES (
        p_local_id, p_user_id, p_date::DATE, p_time, p_slot_type,
        trim(p_name), trim(p_email), trim(p_whatsapp), p_notes,
        'confirmed', p_created_at, p_date_display,
        auth.uid()
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'booking_id', v_id::TEXT);
END;
$$;

REVOKE ALL ON FUNCTION book_slot_atomic FROM public;
GRANT EXECUTE ON FUNCTION book_slot_atomic TO authenticated;

-- ─── cancel_booking_with_refund: aggiunge cancelled_by = auth.uid() ──────────
-- Copia esatta della versione 20260312000000_production_hardening.sql
-- con l'unica aggiunta di cancelled_by nell'UPDATE.

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
        cancelled_by              = auth.uid(),
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

-- ─── user_request_cancellation: aggiunge cancelled_by = auth.uid() ───────────
-- Copia esatta della versione 20260312300000_user_request_cancellation.sql
-- con l'unica aggiunta di cancelled_by nell'UPDATE.

CREATE OR REPLACE FUNCTION user_request_cancellation(
    p_booking_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
    v_booking RECORD;
BEGIN
    SELECT * INTO v_booking FROM bookings WHERE id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'booking_not_found');
    END IF;

    -- Solo il proprietario o admin
    IF v_booking.user_id IS DISTINCT FROM auth.uid() AND NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- Solo booking confermati
    IF v_booking.status <> 'confirmed' THEN
        RETURN jsonb_build_object('success', false, 'error', 'not_confirmed');
    END IF;

    UPDATE bookings
    SET status = 'cancellation_requested',
        cancellation_requested_at = now(),
        cancelled_by = auth.uid()
    WHERE id = p_booking_id;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION user_request_cancellation FROM public;
GRANT EXECUTE ON FUNCTION user_request_cancellation TO authenticated;
GRANT EXECUTE ON FUNCTION user_request_cancellation TO service_role;
