-- ─── Normalizza email a lowercase su tutte le tabelle ──────────────────────────
-- Fix: email case sensitivity causa record duplicati (es. Mario@Gmail.com vs mario@gmail.com)
-- Trigger BEFORE INSERT OR UPDATE forza lower(trim(email)) su ogni riga.

-- 1. Funzione trigger condivisa
CREATE OR REPLACE FUNCTION normalize_email()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.email := lower(trim(NEW.email));
    END IF;
    RETURN NEW;
END;
$$;

-- 2. Applica trigger su tutte le tabelle con colonna email
DO $$
DECLARE
    t TEXT;
BEGIN
    FOR t IN SELECT unnest(ARRAY['bookings','credits','manual_debts','bonuses'])
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_normalize_email ON %I; '
            'CREATE TRIGGER trg_normalize_email BEFORE INSERT OR UPDATE OF email ON %I '
            'FOR EACH ROW EXECUTE FUNCTION normalize_email();',
            t, t
        );
    END LOOP;
END $$;

-- 3. Normalizza dati esistenti
UPDATE bookings      SET email = lower(trim(email)) WHERE email IS DISTINCT FROM lower(trim(email));
UPDATE credits       SET email = lower(trim(email)) WHERE email IS DISTINCT FROM lower(trim(email));
UPDATE manual_debts  SET email = lower(trim(email)) WHERE email IS DISTINCT FROM lower(trim(email));
UPDATE bonuses       SET email = lower(trim(email)) WHERE email IS DISTINCT FROM lower(trim(email));
-- 4. Aggiorna book_slot_atomic per normalizzare esplicitamente
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
    v_count INTEGER;
    v_id    UUID;
    v_email TEXT := lower(trim(p_email));
BEGIN
    -- ── Validazioni input ────────────────────────────────────────────────────
    IF v_email IS NOT NULL AND v_email <> '' AND
       v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_email');
    END IF;

    IF p_date::DATE < current_date THEN
        RETURN jsonb_build_object('success', false, 'error', 'past_date');
    END IF;

    IF p_name IS NULL OR trim(p_name) = '' THEN
        RETURN jsonb_build_object('success', false, 'error', 'missing_name');
    END IF;

    IF p_max_capacity <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', 'invalid_capacity');
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
        trim(p_name), v_email, trim(p_whatsapp), p_notes,
        'confirmed', p_created_at, p_date_display
    )
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('success', true, 'booking_id', v_id::TEXT);
END;
$$;

REVOKE ALL ON FUNCTION book_slot_atomic FROM public;
GRANT EXECUTE ON FUNCTION book_slot_atomic TO authenticated;
