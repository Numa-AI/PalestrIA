-- Expose the explicit client lifecycle state to admin Flutter/PWA rosters.

drop function if exists get_all_profiles_basic();
create function get_all_profiles_basic()
returns table(
  id uuid,name text,email text,whatsapp text,medical_cert_expiry text,
  insurance_expiry text,codice_fiscale text,indirizzo_via text,indirizzo_cap text,
  indirizzo_paese text,documento_firmato boolean,geo_enabled boolean,
  push_enabled boolean,privacy_prenotazioni boolean,archived_at timestamptz
)
language plpgsql stable security definer set search_path=public as $$
declare v_org uuid:=current_org_id();
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  return query select p.id,p.name,p.email,p.whatsapp,p.medical_cert_expiry::text,
    p.insurance_expiry::text,p.codice_fiscale,p.indirizzo_via,p.indirizzo_cap,
    p.indirizzo_paese,p.documento_firmato,p.geo_enabled,p.push_enabled,
    p.privacy_prenotazioni,p.archived_at
    from profiles p where p.org_id=v_org order by (p.archived_at is not null),p.name;
end;
$$;
revoke all on function get_all_profiles_basic() from public,anon;
grant execute on function get_all_profiles_basic() to authenticated;

drop function if exists get_all_profiles();
create function get_all_profiles()
returns table(
  id uuid,name text,email text,whatsapp text,medical_cert_expiry text,
  medical_cert_history jsonb,insurance_expiry text,insurance_history jsonb,
  codice_fiscale text,indirizzo_via text,indirizzo_cap text,indirizzo_paese text,
  documento_firmato boolean,geo_enabled boolean,push_enabled boolean,
  privacy_prenotazioni boolean,archived_at timestamptz
)
language plpgsql stable security definer set search_path=public as $$
declare v_org uuid:=current_org_id();
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  return query select p.id,p.name,p.email,p.whatsapp,p.medical_cert_expiry::text,
    p.medical_cert_history,p.insurance_expiry::text,p.insurance_history,
    p.codice_fiscale,p.indirizzo_via,p.indirizzo_cap,p.indirizzo_paese,
    p.documento_firmato,p.geo_enabled,p.push_enabled,p.privacy_prenotazioni,p.archived_at
    from profiles p where p.org_id=v_org order by (p.archived_at is not null),p.name;
end;
$$;
revoke all on function get_all_profiles() from public,anon;
grant execute on function get_all_profiles() to authenticated;
