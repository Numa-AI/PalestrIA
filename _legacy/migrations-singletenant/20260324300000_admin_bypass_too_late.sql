-- ─── Admin bypassa il check "too_late" in book_slot_atomic ─────────────────
-- L'admin deve poter aggiungere persone a qualsiasi slot, anche passato.

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
        name, email, whatsapp, notes, status, created_at, date_display
    ) VALUES (
        p_local_id, p_user_id, p_date::DATE, p_time, p_slot_type,
        trim(p_name), trim(p_email), trim(p_whatsapp), p_notes,
        'confirmed', p_created_at, p_date_display
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'booking_id', v_id::TEXT);
END;
$$;

REVOKE ALL ON FUNCTION book_slot_atomic FROM public;
GRANT EXECUTE ON FUNCTION book_slot_atomic TO authenticated;
