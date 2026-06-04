-- ─── Proximity tracking: arrivo in palestra + permesso GPS ─────────────
-- arrived_at: timestamp di quando l'utente si è avvicinato alla palestra (GPS proximity)
-- geo_enabled: flag se l'utente ha abilitato il GPS nell'app

-- Colonna arrived_at su bookings
alter table bookings add column if not exists arrived_at timestamptz;

-- Colonna geo_enabled su profiles
alter table profiles add column if not exists geo_enabled boolean not null default false;

-- RPC: segna arrivo per una prenotazione (chiamata dal client quando proximity scatta)
create or replace function mark_booking_arrived(p_booking_id uuid)
returns void language plpgsql security definer as $$
begin
    update bookings
       set arrived_at = now()
     where id = p_booking_id
       and user_id = auth.uid()
       and arrived_at is null;
end;
$$;

-- RPC: aggiorna flag geo_enabled sul profilo (chiamata dal client quando concede il permesso GPS)
create or replace function set_geo_enabled(p_enabled boolean)
returns void language plpgsql security definer as $$
begin
    update profiles
       set geo_enabled = p_enabled
     where id = auth.uid();
end;
$$;

-- RPC admin: elenco user_id con push subscription attiva (per mostrare icone in admin)
create or replace function get_push_enabled_users()
returns setof uuid language sql stable security definer as $$
    select distinct user_id from push_subscriptions where user_id is not null;
$$;

-- Permesso: solo admin può chiamare get_push_enabled_users
revoke execute on function get_push_enabled_users() from public;
grant execute on function get_push_enabled_users() to authenticated;

-- Aggiorna get_all_profiles per restituire anche geo_enabled
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
    geo_enabled          BOOLEAN
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
               p.geo_enabled
        FROM profiles p;
END;
$$;

REVOKE ALL ON FUNCTION get_all_profiles FROM public;
GRANT EXECUTE ON FUNCTION get_all_profiles TO authenticated;
