-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000008_public_company_address
--
-- Espone anche `company.address` (indirizzo dello studio: via, cap, città, provincia,
-- paese) ai client ANONIMI, così la home pubblica (index.html) può mostrare l'indirizzo
-- reale dello studio accanto al link Maps, oltre al link stesso.
--
-- Definizione COMPLETA e finale di get_public_org_settings (include anche company.maps_url
-- della 00000000000007). ⚠️ Espone SOLO `company.maps_url` e `company.address` di company.%:
-- i dati fiscali (P.IVA, codice fiscale, PEC, SDI, prefisso fattura) restano PRIVATI.
-- ──────────────────────────────────────────────────────────────────────────────

create or replace function get_public_org_settings(p_org_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from org_settings
    where org_id = org_id_for_slug(p_org_slug)
      and (
            key like any (array['branding.%','locale.%','booking.policy.%','billing_client.prices%','maintenance.%'])
            or key in ('company.maps_url', 'company.address')
          );
$$;

grant execute on function get_public_org_settings to anon, authenticated;
