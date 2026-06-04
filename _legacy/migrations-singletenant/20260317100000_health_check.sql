-- ─── RPC: admin_health_check — verifica integrità dati ───────────────────────
-- Controlla anomalie: utenti fantasma, booking orfane, email mismatch, ecc.

CREATE OR REPLACE FUNCTION admin_health_check()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_ghost_users   JSONB;
    v_orphan_bookings JSONB;
    v_email_mismatch  JSONB;
    v_orphan_credits  JSONB;
    v_orphan_debts    JSONB;
    v_orphan_bonuses  JSONB;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- 1. Utenti auth senza profilo (fantasma)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'email', au.email,
        'created_at', au.created_at::TEXT
    )), '[]'::JSONB)
    INTO v_ghost_users
    FROM auth.users au
    LEFT JOIN profiles p ON au.id = p.id
    WHERE p.id IS NULL;

    -- 2. Booking con user_id che punta a profilo inesistente
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'booking_id', b.id,
        'email', b.email,
        'date', b.date::TEXT,
        'user_id', b.user_id::TEXT
    )), '[]'::JSONB)
    INTO v_orphan_bookings
    FROM bookings b
    LEFT JOIN profiles p ON b.user_id = p.id
    WHERE b.user_id IS NOT NULL AND p.id IS NULL;

    -- 3. Booking con user_id il cui profilo ha email diversa
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'booking_id', b.id,
        'booking_email', b.email,
        'profile_email', p.email,
        'date', b.date::TEXT
    )), '[]'::JSONB)
    INTO v_email_mismatch
    FROM bookings b
    JOIN profiles p ON b.user_id = p.id
    WHERE b.email IS NOT NULL AND p.email IS NOT NULL
      AND lower(trim(b.email)) <> lower(trim(p.email));

    -- 4. Credits con user_id orfano
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'email', c.email,
        'balance', c.balance,
        'user_id', c.user_id::TEXT
    )), '[]'::JSONB)
    INTO v_orphan_credits
    FROM credits c
    LEFT JOIN profiles p ON c.user_id = p.id
    WHERE c.user_id IS NOT NULL AND p.id IS NULL;

    -- 5. Manual debts con user_id orfano
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'email', d.email,
        'balance', d.balance,
        'user_id', d.user_id::TEXT
    )), '[]'::JSONB)
    INTO v_orphan_debts
    FROM manual_debts d
    LEFT JOIN profiles p ON d.user_id = p.id
    WHERE d.user_id IS NOT NULL AND p.id IS NULL;

    -- 6. Bonuses con user_id orfano
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'email', bo.email,
        'user_id', bo.user_id::TEXT
    )), '[]'::JSONB)
    INTO v_orphan_bonuses
    FROM bonuses bo
    LEFT JOIN profiles p ON bo.user_id = p.id
    WHERE bo.user_id IS NOT NULL AND p.id IS NULL;

    RETURN jsonb_build_object(
        'success', true,
        'ghost_users', v_ghost_users,
        'orphan_bookings', v_orphan_bookings,
        'email_mismatch', v_email_mismatch,
        'orphan_credits', v_orphan_credits,
        'orphan_debts', v_orphan_debts,
        'orphan_bonuses', v_orphan_bonuses
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_health_check FROM public;
GRANT EXECUTE ON FUNCTION admin_health_check TO authenticated;

-- ─── RPC: admin_health_fix — corregge anomalie in modo conservativo ──────────
-- Non cancella MAI dati. Azioni:
--   ghost_users:     crea profilo mancante da auth.users metadata
--   orphan_bookings: setta user_id = NULL (la booking resta, perde solo il link)
--   email_mismatch:  allinea email booking a quella del profilo collegato
--   orphan_credits/debts/bonuses: setta user_id = NULL

CREATE OR REPLACE FUNCTION admin_health_fix()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_fixed_ghosts    INT := 0;
    v_fixed_bookings  INT := 0;
    v_fixed_emails    INT := 0;
    v_fixed_credits   INT := 0;
    v_fixed_debts     INT := 0;
    v_fixed_bonuses   INT := 0;
    r RECORD;
    v_whatsapp TEXT;
BEGIN
    IF NOT is_admin() THEN
        RETURN jsonb_build_object('success', false, 'error', 'unauthorized');
    END IF;

    -- 1. Ghost users: crea profili mancanti (stessa logica di handle_new_user)
    FOR r IN
        SELECT au.id, au.email, au.raw_user_meta_data
        FROM auth.users au
        LEFT JOIN profiles p ON au.id = p.id
        WHERE p.id IS NULL
        ORDER BY au.created_at ASC
    LOOP
        v_whatsapp := COALESCE(r.raw_user_meta_data->>'whatsapp', '');
        -- Evita conflitto unique su whatsapp
        IF v_whatsapp <> '' AND EXISTS(SELECT 1 FROM profiles WHERE whatsapp = v_whatsapp) THEN
            v_whatsapp := '';
        END IF;

        BEGIN
            INSERT INTO profiles (id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap)
            VALUES (
                r.id,
                COALESCE(r.raw_user_meta_data->>'full_name', r.raw_user_meta_data->>'name', split_part(r.email, '@', 1)),
                lower(trim(r.email)),
                v_whatsapp,
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'codice_fiscale', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_via', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_paese', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_cap', '')), '')
            );
            v_fixed_ghosts := v_fixed_ghosts + 1;
        EXCEPTION WHEN unique_violation THEN
            -- Skip silenziosamente
        END;
    END LOOP;

    -- Collega booking orfane ai profili appena creati
    UPDATE bookings b SET user_id = p.id
    FROM profiles p
    WHERE lower(trim(b.email)) = lower(trim(p.email)) AND b.user_id IS NULL;

    -- 2. Orphan bookings: scollega user_id invalido (la booking resta intatta)
    UPDATE bookings b SET user_id = NULL
    FROM (
        SELECT b2.id FROM bookings b2
        LEFT JOIN profiles p ON b2.user_id = p.id
        WHERE b2.user_id IS NOT NULL AND p.id IS NULL
    ) orphans
    WHERE b.id = orphans.id;
    GET DIAGNOSTICS v_fixed_bookings = ROW_COUNT;

    -- 3. Email mismatch: allinea email booking al profilo (il profilo è autoritativo)
    UPDATE bookings b SET email = lower(trim(p.email))
    FROM profiles p
    WHERE b.user_id = p.id
      AND b.email IS NOT NULL AND p.email IS NOT NULL
      AND lower(trim(b.email)) <> lower(trim(p.email));
    GET DIAGNOSTICS v_fixed_emails = ROW_COUNT;

    -- 4. Orphan credits: scollega user_id (il credito resta con email intatta)
    UPDATE credits c SET user_id = NULL
    FROM (
        SELECT c2.id FROM credits c2
        LEFT JOIN profiles p ON c2.user_id = p.id
        WHERE c2.user_id IS NOT NULL AND p.id IS NULL
    ) orphans
    WHERE c.id = orphans.id;
    GET DIAGNOSTICS v_fixed_credits = ROW_COUNT;

    -- 5. Orphan debts: scollega user_id
    UPDATE manual_debts d SET user_id = NULL
    FROM (
        SELECT d2.id FROM manual_debts d2
        LEFT JOIN profiles p ON d2.user_id = p.id
        WHERE d2.user_id IS NOT NULL AND p.id IS NULL
    ) orphans
    WHERE d.id = orphans.id;
    GET DIAGNOSTICS v_fixed_debts = ROW_COUNT;

    -- 6. Orphan bonuses: scollega user_id
    UPDATE bonuses bo SET user_id = NULL
    FROM (
        SELECT bo2.id FROM bonuses bo2
        LEFT JOIN profiles p ON bo2.user_id = p.id
        WHERE bo2.user_id IS NOT NULL AND p.id IS NULL
    ) orphans
    WHERE bo.id = orphans.id;
    GET DIAGNOSTICS v_fixed_bonuses = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'fixed_ghosts', v_fixed_ghosts,
        'fixed_bookings', v_fixed_bookings,
        'fixed_emails', v_fixed_emails,
        'fixed_credits', v_fixed_credits,
        'fixed_debts', v_fixed_debts,
        'fixed_bonuses', v_fixed_bonuses
    );
END;
$$;

REVOKE ALL ON FUNCTION admin_health_fix FROM public;
GRANT EXECUTE ON FUNCTION admin_health_fix TO authenticated;
