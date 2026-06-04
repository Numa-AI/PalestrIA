-- Aggiunge flag "documento firmato" al profilo utente (solo admin può modificarlo)

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS documento_firmato BOOLEAN NOT NULL DEFAULT FALSE;

-- Aggiorna get_all_profiles per restituire anche documento_firmato
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
    indirizzo_cap        TEXT,
    documento_firmato    BOOLEAN
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
               p.indirizzo_via, p.indirizzo_paese, p.indirizzo_cap,
               p.documento_firmato
        FROM profiles p;
END;
$$;

REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
