-- ─── Privacy prenotazioni su profiles ────────────────────────────────────
-- Se true (default), il nome dell'utente NON compare nella lista "Persone iscritte"
-- visibile agli altri utenti nel modal di prenotazione.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS privacy_prenotazioni boolean NOT NULL DEFAULT true;

-- RPC: restituisce i nomi degli iscritti a uno slot.
-- Utenti con privacy_prenotazioni = true compaiono come "Anonimo".
CREATE OR REPLACE FUNCTION get_slot_attendees(p_date date, p_time text)
RETURNS TABLE (name text)
LANGUAGE sql SECURITY DEFINER STABLE AS $$
    SELECT CASE WHEN p.privacy_prenotazioni THEN 'Anonimo' ELSE p.name END AS name
    FROM   bookings b
    JOIN   profiles p ON p.id = b.user_id
    WHERE  b.date = p_date
      AND  b.time = p_time
      AND  b.status = 'confirmed'
    ORDER BY CASE WHEN p.privacy_prenotazioni THEN 1 ELSE 0 END, p.name;
$$;

GRANT EXECUTE ON FUNCTION get_slot_attendees(date, text) TO authenticated;

-- Aggiorna get_all_profiles per restituire anche privacy_prenotazioni
DROP FUNCTION IF EXISTS get_all_profiles();
CREATE OR REPLACE FUNCTION get_all_profiles()
RETURNS TABLE (
    id                      UUID,
    name                    TEXT,
    email                   TEXT,
    whatsapp                TEXT,
    medical_cert_expiry     TEXT,
    medical_cert_history    JSONB,
    insurance_expiry        TEXT,
    insurance_history       JSONB,
    codice_fiscale          TEXT,
    indirizzo_via           TEXT,
    indirizzo_paese         TEXT,
    indirizzo_cap           TEXT,
    documento_firmato       BOOLEAN,
    geo_enabled             BOOLEAN,
    push_enabled            BOOLEAN,
    privacy_prenotazioni    BOOLEAN
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
               p.push_enabled,
               p.privacy_prenotazioni
        FROM profiles p;
END;
$$;

REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
