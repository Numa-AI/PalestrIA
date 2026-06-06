-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000007_public_maps_url
--
-- Espone la chiave `company.maps_url` ai client ANONIMI tramite get_public_org_settings,
-- così la home pubblica (index.html) può usare il link Google Maps configurato in
-- Impostazioni → Dati azienda anche per i visitatori non loggati.
--
-- ⚠️ Si aggiunge SOLO `company.maps_url` (chiave esatta), NON l'intero `company.%`:
-- gli altri dati azienda (P.IVA, codice fiscale, PEC, SDI, indirizzo) restano privati.
-- ──────────────────────────────────────────────────────────────────────────────

create or replace function get_public_org_settings(p_org_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from org_settings
    where org_id = org_id_for_slug(p_org_slug)
      and (
            key like any (array['branding.%','locale.%','booking.policy.%','billing_client.prices%','maintenance.%'])
            or key = 'company.maps_url'
          );
$$;

grant execute on function get_public_org_settings to anon, authenticated;
