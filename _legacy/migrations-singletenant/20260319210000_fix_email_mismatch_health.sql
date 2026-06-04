-- ─── Fix health check email_mismatch ─────────────────────────────────────────
-- Problema: quando l'admin prenota dalla pagina client per conto di un'altra
-- persona, il booking ottiene user_id dell'admin ma l'email del cliente.
-- Il vecchio fix sovrascriveva l'email del booking con quella dell'admin,
-- perdendo l'email reale del cliente.
--
-- Nuovo comportamento:
--   email_mismatch fix → ri-collega il user_id al profilo che matcha l'email
--                         della prenotazione (o NULL se non esiste profilo).
--   L'email della prenotazione NON viene MAI sovrascritta.

-- ─── admin_health_fix: aggiorna solo la sezione email_mismatch ──────────────

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

    -- 3. Email mismatch: ri-collega user_id al profilo che matcha l'email
    --    della prenotazione. Se nessun profilo ha quell'email, setta user_id = NULL.
    --    L'email della prenotazione NON viene MAI modificata.
    UPDATE bookings b
    SET user_id = matching.new_user_id
    FROM (
        SELECT b2.id,
               p_match.id AS new_user_id
        FROM bookings b2
        JOIN profiles p_current ON b2.user_id = p_current.id
        LEFT JOIN profiles p_match ON lower(trim(b2.email)) = lower(trim(p_match.email))
        WHERE b2.email IS NOT NULL AND p_current.email IS NOT NULL
          AND lower(trim(b2.email)) <> lower(trim(p_current.email))
    ) matching
    WHERE b.id = matching.id;
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
