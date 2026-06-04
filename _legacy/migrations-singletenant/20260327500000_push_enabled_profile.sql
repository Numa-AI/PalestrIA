-- ─── Flag push_enabled su profiles ──────────────────────────────────────
-- Traccia se l'utente ha le notifiche push attive (salvato dal client)

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS push_enabled boolean NOT NULL DEFAULT false;

-- RPC: aggiorna flag push_enabled
CREATE OR REPLACE FUNCTION set_push_enabled(p_enabled boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    UPDATE profiles SET push_enabled = p_enabled WHERE id = auth.uid();
END;
$$;

-- Aggiorna get_all_profiles per restituire anche push_enabled
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
    documento_firmato    BOOLEAN,
    geo_enabled          BOOLEAN,
    push_enabled         BOOLEAN
) LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Solo admin';
    END IF;
    RETURN QUERY
        SELECT p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::TEXT, p.medical_cert_history,
               p.insurance_expiry::TEXT, p.insurance_history,
               p.codice_fiscale,
               p.indirizzo_via, p.indirizzo_paese, p.indirizzo_cap,
               p.documento_firmato,
               p.geo_enabled,
               p.push_enabled
        FROM profiles p;
END;
$$;

REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
