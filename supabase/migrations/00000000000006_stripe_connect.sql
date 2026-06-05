-- ══════════════════════════════════════════════════════════════════════════════
-- Stripe Connect (Standard) — ogni trainer collega il PROPRIO account Stripe.
--
-- Obiettivo: i pagamenti dei clienti arrivano DIRETTAMENTE al trainer (commissione
-- piattaforma = 0). La piattaforma fa solo da "ponte" tecnico (OAuth Connect).
-- Salviamo SOLO l'id dell'account connesso (`acct_…`), MAI chiavi segrete.
--
-- Sicurezza: i campi stripe_* di organizations li scrive SOLO il service_role
-- (la edge function stripe-connect, dopo aver verificato il code OAuth). Un admin
-- NON può impostarli a mano dal client → eviterebbe di dirottare gli incassi.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Account connesso per ogni org ─────────────────────────────────────────────
alter table organizations
    add column if not exists stripe_account_id      text,
    add column if not exists stripe_charges_enabled boolean not null default false,
    add column if not exists stripe_account_email   text,
    add column if not exists stripe_connected_at    timestamptz;

create index if not exists organizations_stripe_acct_idx on organizations (stripe_account_id);

-- ── Stato temporaneo del flusso OAuth (anti-CSRF) ─────────────────────────────
-- Lega lo `state` (random) alla org/utente; consumato e cancellato al callback.
create table if not exists stripe_oauth_states (
    state      text primary key,
    org_id     uuid not null references organizations(id) on delete cascade,
    user_id    uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);
alter table stripe_oauth_states enable row level security;
-- Nessuna policy → accessibile solo al service_role (edge function).

-- ── Guardia: stripe_* scrivibili solo dal service_role ────────────────────────
create or replace function _guard_org_stripe_cols()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    if (new.stripe_account_id      is distinct from old.stripe_account_id
        or new.stripe_charges_enabled is distinct from old.stripe_charges_enabled
        or new.stripe_account_email is distinct from old.stripe_account_email
        or new.stripe_connected_at  is distinct from old.stripe_connected_at)
       and coalesce(auth.role(), '') <> 'service_role' then
        raise exception 'stripe_fields_readonly'
            using hint = 'I campi Stripe Connect si impostano solo via edge function (service_role).';
    end if;
    return new;
end;
$$;

drop trigger if exists trg_guard_org_stripe_cols on organizations;
create trigger trg_guard_org_stripe_cols
    before update on organizations
    for each row execute function _guard_org_stripe_cols();

-- ══════════════════════════════════════════════════════════════════════════════
-- Super-admin: espone lo stato Connect di ogni studio (drop+recreate perché
-- cambia la signature della RETURNS TABLE).
-- ══════════════════════════════════════════════════════════════════════════════
drop function if exists admin_platform_organizations();
create or replace function admin_platform_organizations()
returns table (
    org_id                 uuid,
    name                   text,
    slug                   text,
    status                 text,
    created_at             timestamptz,
    created_via            text,
    owner_email            text,
    owner_name             text,
    plan_code              text,
    plan_name              text,
    plan_price             numeric,
    sub_status             text,
    trial_end              timestamptz,
    current_period_end     timestamptz,
    cancel_at_period_end   boolean,
    stripe_customer_id     text,
    client_count           bigint,
    member_count           bigint,
    booking_count          bigint,
    bookings_30d           bigint,
    revenue_total          numeric,
    revenue_30d            numeric,
    last_activity          timestamptz,
    stripe_account_id      text,
    stripe_charges_enabled boolean
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
        ),
        o.stripe_account_id,
        o.stripe_charges_enabled
    from organizations o
    left join subscriptions s on s.org_id = o.id
    left join plans         p on p.id     = s.plan_id
    left join auth.users    u on u.id     = o.owner_user_id
    order by o.created_at desc;
end;
$$;

revoke all on function admin_platform_organizations() from public;
grant execute on function admin_platform_organizations() to authenticated;
