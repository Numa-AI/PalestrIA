-- ══════════════════════════════════════════════════════════════════════════════
-- Fix: la dashboard super-admin mostrava `organizations.name`, ma quando il
-- trainer rinomina lo studio (Impostazioni → Branding) il nuovo nome finisce in
-- org_settings('branding.studio_name'), NON in organizations.name. Risultato: la
-- dashboard mostrava il nome originale dell'iscrizione.
--
-- Soluzione: in admin_platform_organizations() preferiamo il nome di branding
-- (org_settings) con fallback a organizations.name. `value #>> '{}'` estrae la
-- stringa JSON come testo (value è jsonb, es. '"Demo Studio"' → Demo Studio).
-- ══════════════════════════════════════════════════════════════════════════════
create or replace function admin_platform_organizations()
returns table (
    org_id               uuid,
    name                 text,
    slug                 text,
    status               text,
    created_at           timestamptz,
    created_via          text,
    owner_email          text,
    owner_name           text,
    plan_code            text,
    plan_name            text,
    plan_price           numeric,
    sub_status           text,
    trial_end            timestamptz,
    current_period_end   timestamptz,
    cancel_at_period_end boolean,
    stripe_customer_id   text,
    client_count         bigint,
    member_count         bigint,
    booking_count        bigint,
    bookings_30d         bigint,
    revenue_total        numeric,
    revenue_30d          numeric,
    last_activity        timestamptz
) language plpgsql stable security definer set search_path = public as $$
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;

    return query
    select
        o.id,
        coalesce(
            nullif((select os.value #>> '{}' from org_settings os
                     where os.org_id = o.id and os.key = 'branding.studio_name'), ''),
            o.name
        )::text,
        o.slug,
        o.status,
        o.created_at,
        o.created_via,
        u.email::text,
        coalesce(u.raw_user_meta_data ->> 'name', u.raw_user_meta_data ->> 'full_name', '')::text,
        p.code,
        p.name,
        p.price_eur,
        s.status,
        s.trial_end,
        s.current_period_end,
        s.cancel_at_period_end,
        s.stripe_customer_id,
        (select count(*) from profiles    pr where pr.org_id = o.id),
        (select count(*) from org_members  m where  m.org_id = o.id and m.status = 'active'),
        (select count(*) from bookings     b where  b.org_id = o.id),
        (select count(*) from bookings     b where  b.org_id = o.id and b.created_at > now() - interval '30 days'),
        (select coalesce(sum(pay.amount), 0) from payments pay where pay.org_id = o.id),
        (select coalesce(sum(pay.amount), 0) from payments pay where pay.org_id = o.id and pay.created_at > now() - interval '30 days'),
        greatest(
            (select max(b.created_at) from bookings b where b.org_id = o.id),
            o.updated_at
        )
    from organizations o
    left join subscriptions s on s.org_id = o.id
    left join plans         p on p.id     = s.plan_id
    left join auth.users    u on u.id     = o.owner_user_id
    order by o.created_at desc;
end;
$$;
