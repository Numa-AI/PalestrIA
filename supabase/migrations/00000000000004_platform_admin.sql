-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — Layer "Super-Admin di piattaforma" (cross-tenant)
--
-- PROBLEMA: tutto lo schema è org-scoped via RLS. Nemmeno l'owner della
-- piattaforma può vedere gli altri studi: è IL comportamento corretto per i
-- tenant, ma serve un livello separato per chi gestisce l'intera piattaforma.
--
-- SOLUZIONE: una whitelist `platform_admins` + funzioni SECURITY DEFINER che
-- VERIFICANO `is_platform_admin()` PRIMA di bypassare la RLS. Senza quel check
-- una RPC SECURITY DEFINER esporrebbe i dati di TUTTI i tenant: è il data-leak
-- #1 citato in CLAUDE.md. Ogni RPC qui dentro fa il check come prima riga.
--
-- ACCESSO APERTO (fase di sviluppo): `platform_settings.open_access` di default
-- è TRUE → la dashboard è raggiungibile da chiunque sia loggato. Per chiuderla a
-- una singola email basta MODIFICARE UN RECORD (nessun deploy di codice):
--
--     -- 1) autorizza la tua email come unico super-admin
--     insert into platform_admins (user_id, email)
--     select id, email from auth.users where lower(email) = lower('TUA@EMAIL.IT')
--     on conflict (user_id) do nothing;
--     -- 2) chiudi l'accesso aperto
--     update platform_settings set open_access = false;
--
-- (esiste anche la RPC `admin_platform_lock(email)` che fa entrambe le cose).
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Whitelist dei super-admin di piattaforma ──────────────────────────────────
create table if not exists platform_admins (
    user_id    uuid primary key references auth.users(id) on delete cascade,
    email      text,
    created_at timestamptz not null default now(),
    note       text
);

-- ── Config globale di piattaforma (riga singola) ──────────────────────────────
create table if not exists platform_settings (
    id          boolean primary key default true check (id),   -- forza riga unica
    open_access boolean not null default true,                 -- accesso aperto (dev)
    updated_at  timestamptz not null default now()
);
insert into platform_settings (id, open_access) values (true, true)
    on conflict (id) do nothing;

alter table platform_admins   enable row level security;
alter table platform_settings enable row level security;

-- ── Helper: è l'utente un super-admin di piattaforma? ─────────────────────────
-- TRUE se l'accesso è "aperto" (fase dev) OPPURE l'utente è nella whitelist.
create or replace function is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
    select coalesce((select open_access from platform_settings where id), false)
        or exists (select 1 from platform_admins where user_id = auth.uid());
$$;

-- Lettura delle tabelle di config riservata ai super-admin (le RPC SECURITY
-- DEFINER bypassano comunque la RLS; questa policy serve a query dirette).
drop policy if exists platform_admins_read on platform_admins;
create policy platform_admins_read on platform_admins
    for select to authenticated using (is_platform_admin());

drop policy if exists platform_settings_read on platform_settings;
create policy platform_settings_read on platform_settings
    for select to authenticated using (is_platform_admin());

-- ══════════════════════════════════════════════════════════════════════════════
-- RPC 1 — KPI di piattaforma (cruscotto in alto)
-- ══════════════════════════════════════════════════════════════════════════════
create or replace function admin_platform_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;

    select jsonb_build_object(
        'total_orgs',        (select count(*) from organizations),
        'orgs_trialing',     (select count(*) from organizations where status = 'trialing'),
        'orgs_active',       (select count(*) from organizations where status = 'active'),
        'orgs_past_due',     (select count(*) from organizations where status = 'past_due'),
        'orgs_suspended',    (select count(*) from organizations where status = 'suspended'),
        'orgs_cancelled',    (select count(*) from organizations where status = 'cancelled'),
        'new_orgs_30d',      (select count(*) from organizations where created_at > now() - interval '30 days'),
        'trials_expiring_7d',(select count(*) from subscriptions
                                  where status = 'trialing'
                                    and trial_end is not null
                                    and trial_end between now() and now() + interval '7 days'),
        'total_clients',     (select count(*) from profiles),
        'total_bookings',    (select count(*) from bookings),
        -- MRR: somma dei canoni mensili degli abbonamenti SaaS ATTIVI (i trial non pagano)
        'mrr',               (select coalesce(sum(p.price_eur), 0)
                                  from subscriptions s join plans p on p.id = s.plan_id
                                  where s.status = 'active'),
        -- GMV cliente: totale incassato dai trainer sui propri clienti (ledger payments)
        'gmv_clients_total', (select coalesce(sum(amount), 0) from payments),
        'gmv_clients_30d',   (select coalesce(sum(amount), 0) from payments
                                  where created_at > now() - interval '30 days')
    ) into result;

    return result;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- RPC 2 — Elenco di tutti gli studi (trainer) con metriche aggregate
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
        o.name,
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

-- ══════════════════════════════════════════════════════════════════════════════
-- RPC 3 — Azioni di gestione su uno studio (suspend / reactivate)
-- ══════════════════════════════════════════════════════════════════════════════
create or replace function admin_platform_set_org_status(p_org_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;
    if p_status not in ('trialing','active','past_due','suspended','cancelled') then
        raise exception 'invalid_status: %', p_status;
    end if;
    update organizations set status = p_status, updated_at = now() where id = p_org_id;
    if not found then raise exception 'org_not_found'; end if;
end;
$$;

-- ── Estendi il trial dello studio di N giorni ─────────────────────────────────
create or replace function admin_platform_extend_trial(p_org_id uuid, p_days integer default 30)
returns void language plpgsql security definer set search_path = public as $$
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;
    if p_days is null or p_days <= 0 or p_days > 365 then
        raise exception 'invalid_days: %', p_days;
    end if;
    update subscriptions
       set trial_end = greatest(coalesce(trial_end, now()), now()) + make_interval(days => p_days),
           status    = 'trialing',
           updated_at = now()
     where org_id = p_org_id;
    if not found then raise exception 'subscription_not_found'; end if;
    update organizations set status = 'trialing', updated_at = now()
     where id = p_org_id and status in ('suspended','cancelled','past_due','trialing');
end;
$$;

-- ── Cambia il piano SaaS dello studio (per codice piano) ──────────────────────
create or replace function admin_platform_set_plan(p_org_id uuid, p_plan_code text)
returns void language plpgsql security definer set search_path = public as $$
declare v_plan uuid;
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;
    select id into v_plan from plans where code = p_plan_code and active;
    if v_plan is null then raise exception 'plan_not_found: %', p_plan_code; end if;
    update subscriptions set plan_id = v_plan, updated_at = now() where org_id = p_org_id;
    if not found then raise exception 'subscription_not_found'; end if;
end;
$$;

-- ══════════════════════════════════════════════════════════════════════════════
-- RPC 4 — Chiusura accesso: autorizza una email e disattiva l'accesso aperto.
-- Da usare quando vuoi passare da "aperto a tutti" a "solo la mia email".
-- ══════════════════════════════════════════════════════════════════════════════
create or replace function admin_platform_lock(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
    if not is_platform_admin() then
        raise exception 'unauthorized' using errcode = '42501';
    end if;
    select id into v_uid from auth.users where lower(email) = lower(trim(p_email)) limit 1;
    if v_uid is null then raise exception 'user_not_found: %', p_email; end if;
    insert into platform_admins (user_id, email) values (v_uid, lower(trim(p_email)))
        on conflict (user_id) do nothing;
    update platform_settings set open_access = false, updated_at = now() where id;
end;
$$;

-- ── Grants: tutte le RPC sono per utenti autenticati; l'autorizzazione vera è
--    dentro la funzione (is_platform_admin). Niente accesso anon. ──────────────
revoke all on function is_platform_admin()                           from public;
revoke all on function admin_platform_overview()                     from public;
revoke all on function admin_platform_organizations()                from public;
revoke all on function admin_platform_set_org_status(uuid, text)     from public;
revoke all on function admin_platform_extend_trial(uuid, integer)    from public;
revoke all on function admin_platform_set_plan(uuid, text)           from public;
revoke all on function admin_platform_lock(text)                     from public;

grant execute on function is_platform_admin()                        to authenticated;
grant execute on function admin_platform_overview()                  to authenticated;
grant execute on function admin_platform_organizations()             to authenticated;
grant execute on function admin_platform_set_org_status(uuid, text)  to authenticated;
grant execute on function admin_platform_extend_trial(uuid, integer) to authenticated;
grant execute on function admin_platform_set_plan(uuid, text)        to authenticated;
grant execute on function admin_platform_lock(text)                  to authenticated;
