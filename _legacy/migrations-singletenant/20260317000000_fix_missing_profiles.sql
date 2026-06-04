-- ─── Fix: profili mancanti + trigger handle_new_user robusto ─────────────────
-- Il trigger precedente (indirizzo_residenza.sql) aveva rimosso SET search_path = public
-- e usava ON CONFLICT (id) che non gestiva conflitti su email/whatsapp unique.
-- Risultato: 52+ utenti in auth.users senza riga in profiles.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Backfill: crea profili mancanti da auth.users + user_metadata
-- ═══════════════════════════════════════════════════════════════════════════════
-- Usa DO block per inserire uno alla volta e gestire conflitti whatsapp unique
DO $$
DECLARE
    r RECORD;
    v_whatsapp TEXT;
BEGIN
    FOR r IN
        SELECT au.id, au.email, au.raw_user_meta_data
        FROM auth.users au
        LEFT JOIN profiles p ON au.id = p.id
        WHERE p.id IS NULL
        ORDER BY au.created_at ASC
    LOOP
        v_whatsapp := COALESCE(r.raw_user_meta_data->>'whatsapp', '');
        -- Se il whatsapp è già usato, inserisci con whatsapp vuoto
        IF v_whatsapp <> '' AND EXISTS(SELECT 1 FROM profiles WHERE whatsapp = v_whatsapp) THEN
            v_whatsapp := '';
        END IF;

        BEGIN
            INSERT INTO profiles (id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap)
            VALUES (
                r.id,
                COALESCE(
                    r.raw_user_meta_data->>'full_name',
                    r.raw_user_meta_data->>'name',
                    split_part(r.email, '@', 1)
                ),
                lower(trim(r.email)),
                v_whatsapp,
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'codice_fiscale', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_via', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_paese', '')), ''),
                NULLIF(TRIM(COALESCE(r.raw_user_meta_data->>'indirizzo_cap', '')), '')
            );
            RAISE NOTICE 'Created profile for %', r.email;
        EXCEPTION WHEN unique_violation THEN
            RAISE WARNING 'Skipped % due to unique violation', r.email;
        END;
    END LOOP;
END $$;

-- Collega prenotazioni orfane ai nuovi profili (stessa logica di link_anonymous_on_register)
UPDATE bookings b
SET user_id = p.id
FROM profiles p
WHERE lower(trim(b.email)) = lower(trim(p.email))
  AND b.user_id IS NULL;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Fix trigger: ripristina SET search_path, gestisci conflitti email/whatsapp
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    -- Normalizza il whatsapp in ingresso per evitare conflitti con l'indice unique
    -- Se il whatsapp è già usato da un altro utente, inserisci con whatsapp vuoto
    -- (l'utente lo aggiornerà dal form Completa Profilo)
    DECLARE
        v_whatsapp TEXT := COALESCE(new.raw_user_meta_data->>'whatsapp', '');
        v_taken    BOOLEAN := false;
    BEGIN
        IF v_whatsapp <> '' THEN
            SELECT EXISTS(
                SELECT 1 FROM profiles WHERE whatsapp = v_whatsapp AND id <> new.id
            ) INTO v_taken;
            IF v_taken THEN
                v_whatsapp := '';
            END IF;
        END IF;

        INSERT INTO profiles (id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap)
        VALUES (
            new.id,
            COALESCE(
                new.raw_user_meta_data->>'full_name',
                new.raw_user_meta_data->>'name',
                split_part(new.email, '@', 1)
            ),
            lower(trim(new.email)),
            v_whatsapp,
            NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'codice_fiscale', '')), ''),
            NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'indirizzo_via', '')), ''),
            NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'indirizzo_paese', '')), ''),
            NULLIF(TRIM(COALESCE(new.raw_user_meta_data->>'indirizzo_cap', '')), '')
        )
        ON CONFLICT (id) DO UPDATE SET
            name     = EXCLUDED.name,
            email    = EXCLUDED.email,
            whatsapp = CASE WHEN EXCLUDED.whatsapp <> '' THEN EXCLUDED.whatsapp ELSE profiles.whatsapp END,
            codice_fiscale  = COALESCE(EXCLUDED.codice_fiscale, profiles.codice_fiscale),
            indirizzo_via   = COALESCE(EXCLUDED.indirizzo_via, profiles.indirizzo_via),
            indirizzo_paese = COALESCE(EXCLUDED.indirizzo_paese, profiles.indirizzo_paese),
            indirizzo_cap   = COALESCE(EXCLUDED.indirizzo_cap, profiles.indirizzo_cap);
    EXCEPTION WHEN unique_violation THEN
        -- Conflitto su email unique (non dovrebbe succedere, Supabase auth lo previene)
        -- Logga ma non bloccare il login
        RAISE LOG 'handle_new_user unique_violation for %: %', new.email, SQLERRM;
    WHEN OTHERS THEN
        RAISE WARNING 'handle_new_user FAILED for %: % (state %)', new.email, SQLERRM, SQLSTATE;
    END;
    RETURN new;
END;
$$;
