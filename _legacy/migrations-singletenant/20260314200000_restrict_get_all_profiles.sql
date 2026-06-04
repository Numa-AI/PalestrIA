-- ─── Protegge get_all_profiles: solo admin ─────────────────────────────────────
-- Prima era accessibile ad anon — chiunque con l'URL Supabase poteva leggere tutti i profili.

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
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Accesso negato: richiesto ruolo admin';
    END IF;

    RETURN QUERY
        SELECT p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::TEXT, p.medical_cert_history,
               p.insurance_expiry::TEXT, p.insurance_history,
               p.codice_fiscale
        FROM profiles p;
END;
$$;

-- Solo authenticated (l'admin è un utente autenticato con claim role=admin)
REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
