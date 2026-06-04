-- Add codice_fiscale column to profiles
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS codice_fiscale TEXT DEFAULT NULL;

-- Update handle_new_user trigger to save codice_fiscale from user_metadata
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    INSERT INTO public.profiles (id, name, email, whatsapp, codice_fiscale)
    VALUES (
        new.id,
        coalesce(
            new.raw_user_meta_data->>'full_name',
            new.raw_user_meta_data->>'name',
            split_part(new.email, '@', 1)
        ),
        new.email,
        coalesce(new.raw_user_meta_data->>'whatsapp', ''),
        nullif(trim(coalesce(new.raw_user_meta_data->>'codice_fiscale', '')), '')
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN new;
END;
$$;

-- Update get_all_profiles to include codice_fiscale
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
    codice_fiscale       TEXT
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    RETURN QUERY
        SELECT p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::TEXT, p.medical_cert_history,
               p.insurance_expiry::TEXT, p.insurance_history,
               p.codice_fiscale
        FROM profiles p;
END;
$$;

GRANT EXECUTE ON FUNCTION get_all_profiles TO anon;
