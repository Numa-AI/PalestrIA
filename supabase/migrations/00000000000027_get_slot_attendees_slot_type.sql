-- 00000000000027_get_slot_attendees_slot_type.sql
-- get_slot_attendees ora ritorna ANCHE slot_type, così il calendario cliente può
-- raggruppare gli iscritti per tipo di lezione quando uno slot ospita 2+ tipi
-- (es. Lezione di Gruppo + un posto Autonomia extra sullo stesso orario).
--
-- Cambio di FIRMA di ritorno (table(name) → table(name, slot_type)) → serve DROP + CREATE
-- (CREATE OR REPLACE non basta per cambiare il tipo di ritorno). Ripristina la postura
-- di sicurezza esistente: SECURITY DEFINER STABLE, SET search_path = public, org-scoping
-- via org_id_for_slug(slug), privacy_prenotazioni → 'Anonimo', e i grant anon/authenticated
-- (funzione nella allowlist pubblica hardening 0022 → resta accessibile ad anon).
-- Idempotente. Da applicare a mano nel SQL Editor di Supabase.

drop function if exists get_slot_attendees(text, date, text);

create function get_slot_attendees(p_org_slug text, p_date date, p_time text)
returns table(name text, slot_type text)
language sql stable security definer set search_path = public as $$
    select case when p.privacy_prenotazioni then 'Anonimo' else p.name end as name,
           b.slot_type
    from   bookings b
    join   profiles p on p.id = b.user_id and p.org_id = b.org_id
    where  b.org_id = org_id_for_slug(p_org_slug)
      and  b.date   = p_date
      and  b.time   = p_time
      and  b.status = 'confirmed'
    order by b.slot_type, case when p.privacy_prenotazioni then 1 else 0 end, p.name;
$$;

revoke all on function get_slot_attendees(text, date, text) from public;
grant execute on function get_slot_attendees(text, date, text) to anon, authenticated;
