-- Aggiunge indirizzo di residenza (via, paese, CAP) al profilo utente

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS indirizzo_via   TEXT DEFAULT NULL;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS indirizzo_paese TEXT DEFAULT NULL;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS indirizzo_cap   TEXT DEFAULT NULL;

-- Aggiorna handle_new_user per includere i campi indirizzo dal metadata
-- EXCEPTION WHEN OTHERS evita che errori nel trigger blocchino il login
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    BEGIN
        INSERT INTO profiles (id, name, email, whatsapp, codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap)
        VALUES (
            new.id,
            COALESCE(
                new.raw_user_meta_data->>'full_name',
                new.raw_user_meta_data->>'name',
                split_part(new.email, '@', 1)
            ),
            new.email,
            COALESCE(new.raw_user_meta_data->>'whatsapp', ''),
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
    EXCEPTION WHEN OTHERS THEN
        RAISE LOG 'handle_new_user FAILED for %: % %', new.email, SQLERRM, SQLSTATE;
    END;
    RETURN new;
END;
$$;

-- Aggiorna get_all_profiles per restituire anche indirizzo
DROP FUNCTION IF EXISTS get_all_profiles();
CREATE OR REPLACE FUNCTION get_all_profiles()
RETURNS TABLE (
    id                   UUID,
    name                 TEXT,
    email                TEXT,
    whatsapp             TEXT,
    medical_cert_expiry  TEXT,
    medical_cert_history JSONB,
    insurance_expiry     TEXT,
    insurance_history    JSONB,
    codice_fiscale       TEXT,
    indirizzo_via        TEXT,
    indirizzo_paese      TEXT,
    indirizzo_cap        TEXT
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    RETURN QUERY
        SELECT p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::TEXT, p.medical_cert_history,
               p.insurance_expiry::TEXT, p.insurance_history,
               p.codice_fiscale,
               p.indirizzo_via, p.indirizzo_paese, p.indirizzo_cap
        FROM profiles p;
END;
$$;

REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
