-- ─────────────────────────────────────────────────────────────────────────────
-- get_all_profiles_basic — variante leggera di get_all_profiles SENZA le history JSONB.
--
-- MOTIVO (egress): get_all_profiles() restituisce anche medical_cert_history e
-- insurance_history (JSONB append-only, in crescita illimitata). Queste history NON
-- vengono mai mostrate né scritte lato admin (l'admin persiste solo lo scalare
-- medical_cert_expiry/insurance_expiry — vedi admin-clients.js / admin-analytics.js);
-- il path utente legge la propria history da _loadProfile (auth.js, indipendente) e il
-- backup completo usa la get_all_profiles full diretta. Il sync frequente dei profili in
-- UserStorage (ogni load admin + reconcile) scaricava però le history a vuoto.
-- Questa RPC è identica alla full ma omette le 2 colonne history → payload più leggero.
--
-- Sicurezza: SECURITY DEFINER + set search_path = public, gate is_org_admin(), filtro
-- org_id = current_org_id() (stesso pattern di get_all_profiles → niente leak cross-tenant).
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function get_all_profiles_basic()
returns table (
    id                   uuid,
    name                 text,
    email                text,
    whatsapp             text,
    medical_cert_expiry  text,
    insurance_expiry     text,
    codice_fiscale       text,
    indirizzo_via        text,
    indirizzo_cap        text,
    indirizzo_paese      text,
    documento_firmato    boolean,
    geo_enabled          boolean,
    push_enabled         boolean,
    privacy_prenotazioni boolean
)
language plpgsql stable security definer set search_path = public as $$
declare
    v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;
    return query
        select p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::text,
               p.insurance_expiry::text,
               p.codice_fiscale,
               p.indirizzo_via, p.indirizzo_cap, p.indirizzo_paese,
               p.documento_firmato, p.geo_enabled, p.push_enabled,
               p.privacy_prenotazioni
        from profiles p
        where p.org_id = v_org
        order by p.name;
end;
$$;
revoke all on function get_all_profiles_basic() from public;
grant execute on function get_all_profiles_basic() to authenticated;
