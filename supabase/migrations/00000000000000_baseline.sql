-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — Baseline consolidata (progetto Supabase greenfield)
-- Multi-tenant pooled: org_id + RLS. Sostituisce le ~125 migration single-tenant.
--
-- Ordine: estensioni → tenancy → helper → business → scheduling → billing-cliente
--         → billing-SaaS → settings → workout → notifiche → RLS → RPC → seed-hook.
--
-- REGOLA: ogni tabella business ha org_id NOT NULL + RLS org-scoped. Nessuna
-- policy USING(true). Le RPC SECURITY DEFINER filtrano sempre org_id.
-- ══════════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 1 — TENANCY
-- ─────────────────────────────────────────────────────────────────────────────

create table organizations (
    id              uuid primary key default gen_random_uuid(),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    name            text not null,
    slug            text not null unique,
    owner_user_id   uuid references auth.users(id) on delete set null,
    timezone        text not null default 'Europe/Rome',
    currency        text not null default 'EUR',
    locale          text not null default 'it',
    branding        jsonb not null default '{}'::jsonb,
    status          text not null default 'trialing'
                    check (status in ('trialing','active','past_due','suspended','cancelled')),
    created_via     text default 'self_serve'
);
create index organizations_slug_idx on organizations (slug);

create table org_members (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    user_id     uuid not null references auth.users(id) on delete cascade,
    role        text not null check (role in ('owner','admin','staff')),
    status      text not null default 'active' check (status in ('active','invited','revoked')),
    invited_email text,
    created_at  timestamptz not null default now(),
    unique (org_id, user_id)
);
create index org_members_user_idx on org_members (user_id);
create index org_members_org_idx  on org_members (org_id);

-- profiles = clienti finali della org (lo staff sta in org_members)
create table profiles (
    id                   uuid primary key references auth.users(id) on delete cascade,
    org_id               uuid not null references organizations(id) on delete cascade,
    created_at           timestamptz not null default now(),
    name                 text not null,
    email                text not null,
    whatsapp             text,
    medical_cert_expiry  date,
    medical_cert_history jsonb not null default '[]'::jsonb,
    insurance_expiry     date,
    insurance_history    jsonb not null default '[]'::jsonb,
    codice_fiscale       text,
    indirizzo_via        text,
    indirizzo_cap        text,
    indirizzo_paese      text,
    documento_firmato    boolean not null default false,
    privacy_prenotazioni boolean not null default true,
    push_enabled         boolean not null default false,
    geo_enabled          boolean not null default false,
    unique (org_id, email)
);
create index profiles_org_idx on profiles (org_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 2 — HELPER SQL (tenancy-aware). Definiti prima delle policy.
-- ─────────────────────────────────────────────────────────────────────────────

-- org corrente: claim JWT app_metadata.org_id, fallback org_members poi profiles.
create or replace function current_org_id()
returns uuid language sql stable security definer set search_path = public as $$
    select coalesce(
        nullif(auth.jwt() -> 'app_metadata' ->> 'org_id', '')::uuid,
        (select org_id from org_members where user_id = auth.uid() and status = 'active' order by created_at limit 1),
        (select org_id from profiles    where id      = auth.uid())
    )
$$;

-- ruolo org corrente (da claim, fallback membership)
create or replace function current_org_role()
returns text language sql stable security definer set search_path = public as $$
    select coalesce(
        nullif(auth.jwt() -> 'app_metadata' ->> 'org_role', ''),
        (select role from org_members where user_id = auth.uid() and status = 'active'
            and org_id = current_org_id() limit 1)
    )
$$;

create or replace function is_org_admin(p_org_id uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from org_members m
        where m.user_id = auth.uid()
          and m.status  = 'active'
          and m.role in ('owner','admin')
          and m.org_id  = coalesce(p_org_id, current_org_id())
    )
$$;

-- compat: i call-site storici usano is_admin() → ora org-scoped
create or replace function is_admin()
returns boolean language sql stable security definer set search_path = public as $$
    select is_org_admin()
$$;

create or replace function org_id_for_slug(p_slug text)
returns uuid language sql stable security definer set search_path = public as $$
    select id from organizations where slug = lower(trim(p_slug)) and status <> 'cancelled'
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 3 — BUSINESS: bookings (tenant-aware, niente credito)
-- ─────────────────────────────────────────────────────────────────────────────

create table bookings (
    id                          uuid primary key default gen_random_uuid(),
    org_id                      uuid not null references organizations(id) on delete cascade,
    local_id                    text,
    user_id                     uuid references profiles(id) on delete set null,
    created_at                  timestamptz not null default now(),
    updated_at                  timestamptz not null default now(),
    date                        date not null,
    time                        text not null,
    slot_type                   text not null,
    slot_type_id                uuid,                       -- FK slot_types (set sotto)
    name                        text not null,
    email                       text,
    whatsapp                    text,
    notes                       text,
    date_display                text,
    status                      text not null default 'confirmed',
    paid                        boolean not null default false,
    payment_method              text,
    paid_at                     timestamptz,
    custom_price                numeric(10,2),
    billing_model_snapshot      text check (billing_model_snapshot is null or billing_model_snapshot in ('pay_per_session','package','monthly','free')),
    billing_voided_at           timestamptz,
    billing_void_reason         text,
    -- Tracciano QUALE pacchetto/abbonamento è stato consumato da questa prenotazione,
    -- per restituire la sessione/quota in caso di cancellazione (refund deterministico).
    -- uuid "soft" (no FK): le tabelle billing sono create più sotto e il refund gestisce
    -- comunque le righe eventualmente sparite.
    consumed_package_id         uuid,
    reserved_package_id         uuid,
    package_consumed_at         timestamptz,
    consumed_membership_id      uuid,
    cancellation_requested_at   timestamptz,
    cancelled_at                timestamptz,
    cancelled_payment_method    text,
    cancelled_paid_at           timestamptz,
    cancelled_refund_pct        integer,
    created_by                  uuid,
    cancelled_by                uuid,
    arrived_at                  timestamptz,
    reminder_24h_sent           boolean not null default false,
    reminder_1h_sent            boolean not null default false
);
create index bookings_org_date_idx       on bookings (org_id, date);
create index bookings_org_date_time_idx  on bookings (org_id, date, time);
create index bookings_org_email_idx      on bookings (org_id, email);
create index bookings_user_idx           on bookings (user_id);
create index bookings_active_slot_idx    on bookings (org_id, date, time, slot_type)
    where status in ('confirmed','cancellation_requested');

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 4 — SCHEDULING FLESSIBILE
-- ─────────────────────────────────────────────────────────────────────────────

create table slot_types (
    id               uuid primary key default gen_random_uuid(),
    org_id           uuid not null references organizations(id) on delete cascade,
    key              text not null,                          -- es. 'personal-training'
    label            text not null,
    color            text default '#8B5CF6',
    default_capacity integer not null default 1,
    default_price    numeric(10,2) not null default 0,
    bookable         boolean not null default true,
    is_active        boolean not null default true,
    trainer_id       uuid references auth.users(id) on delete set null,  -- opzionale: orari per-trainer
    sort_order       integer not null default 0,
    created_at       timestamptz not null default now(),
    unique (org_id, key)
);
create index slot_types_org_idx on slot_types (org_id);

create table time_slots_config (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    start_time  time not null,
    end_time    time not null,
    label       text,
    sort_order  integer not null default 0,
    is_active   boolean not null default true,
    created_at  timestamptz not null default now(),
    unique (org_id, start_time, end_time)
);
create index time_slots_config_org_idx on time_slots_config (org_id);

create table weekly_schedule_templates (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    name        text not null,
    is_active   boolean not null default false,
    created_at  timestamptz not null default now()
);
create index weekly_schedule_templates_org_idx on weekly_schedule_templates (org_id);

create table weekly_template_slots (
    id            uuid primary key default gen_random_uuid(),
    template_id   uuid not null references weekly_schedule_templates(id) on delete cascade,
    org_id        uuid not null references organizations(id) on delete cascade,
    weekday       smallint not null check (weekday between 0 and 6),  -- 0=Domenica
    time_slot_id  uuid not null references time_slots_config(id) on delete cascade,
    slot_type_id  uuid not null references slot_types(id) on delete cascade,
    capacity      integer,                                   -- null = default_capacity dello slot_type
    unique (template_id, weekday, time_slot_id)
);
create index weekly_template_slots_lookup_idx on weekly_template_slots (template_id, weekday, time_slot_id);

-- override puntuale per-data: capienza ASSOLUTA (rimpiazza base+extras)
create table schedule_overrides (
    id              uuid primary key default gen_random_uuid(),
    org_id          uuid not null references organizations(id) on delete cascade,
    created_at      timestamptz not null default now(),
    date            date not null,
    time            text not null,
    slot_type       text,
    slot_type_id    uuid references slot_types(id) on delete set null,
    capacity        integer,                                 -- capienza assoluta per quello slot/data
    client_name     text,
    client_email    text,
    client_whatsapp text,
    booking_id      text,
    unique (org_id, date, time)
);
create index schedule_overrides_org_date_idx on schedule_overrides (org_id, date);

-- bookings.slot_type_id → slot_types
alter table bookings
    add constraint bookings_slot_type_id_fkey
    foreign key (slot_type_id) references slot_types(id) on delete set null;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 5 — BILLING-CLIENTE CONFIGURABILE (sostituisce crediti/debiti/bonus)
-- ─────────────────────────────────────────────────────────────────────────────

-- config per-org del modello di fatturazione cliente
create table billing_settings (
    org_id                     uuid primary key references organizations(id) on delete cascade,
    default_model              text not null default 'pay_per_session'
                               check (default_model in ('pay_per_session','monthly','package','free')),
    block_unpaid_threshold     numeric(10,2) not null default 0,    -- 0 = nessun blocco
    block_if_membership_expired boolean not null default true,
    block_if_no_package        boolean not null default true,
    grace_days                 integer not null default 0,
    package_auto_decrement     boolean not null default true,
    default_membership_period  text not null default 'monthly'
                               check (default_membership_period in ('monthly','quarterly','annual')),
    package_label              text not null default 'Pacchetto 10 ingressi',
    package_sessions           integer not null default 10 check (package_sessions between 1 and 10000),
    package_price              numeric(10,2) not null default 0 check (package_price >= 0),
    membership_monthly_price   numeric(10,2) not null default 0 check (membership_monthly_price >= 0),
    membership_quarterly_price numeric(10,2) not null default 0 check (membership_quarterly_price >= 0),
    membership_annual_price    numeric(10,2) not null default 0 check (membership_annual_price >= 0),
    model_changed_at           timestamptz not null default now(),
    updated_at                 timestamptz not null default now()
);

-- override per-cliente del modello/prezzo
create table client_billing_profiles (
    id             uuid primary key default gen_random_uuid(),
    org_id         uuid not null references organizations(id) on delete cascade,
    user_id        uuid references profiles(id) on delete cascade,
    client_email   text,
    model_override text check (model_override in ('pay_per_session','monthly','package','free')),
    membership_period_override text check (membership_period_override in ('monthly','quarterly','annual')),
    custom_price   numeric(10,2),
    notes          text,
    created_at     timestamptz not null default now(),
    unique (org_id, user_id)
);
create index client_billing_profiles_org_idx on client_billing_profiles (org_id);

-- abbonamento mensile del cliente (membership)
create table client_memberships (
    id             uuid primary key default gen_random_uuid(),
    org_id         uuid not null references organizations(id) on delete cascade,
    user_id        uuid not null references profiles(id) on delete cascade,
    plan_label     text,
    billing_period text not null default 'monthly' check (billing_period in ('monthly','quarterly','annual')),
    period_start   date not null,
    period_end     date not null,
    lessons_quota  integer,                                  -- null = illimitato
    lessons_used   integer not null default 0,
    status         text not null default 'active' check (status in ('active','expired','cancelled')),
    auto_renew     boolean not null default false,
    price          numeric(10,2),
    created_at     timestamptz not null default now()
);
create index client_memberships_org_user_idx on client_memberships (org_id, user_id);
create index client_memberships_active_idx    on client_memberships (org_id, user_id, status, period_end);

-- pacchetto / carnet prepagato
create table client_packages (
    id                 uuid primary key default gen_random_uuid(),
    org_id             uuid not null references organizations(id) on delete cascade,
    user_id            uuid not null references profiles(id) on delete cascade,
    label              text,
    total_sessions     integer not null,
    remaining_sessions integer not null,
    purchased_at       timestamptz not null default now(),
    expires_at         date,                                 -- null = non scade
    status             text not null default 'active' check (status in ('active','exhausted','expired','cancelled')),
    price              numeric(10,2),
    created_at         timestamptz not null default now()
);
create index client_packages_org_user_idx on client_packages (org_id, user_id);
create index client_packages_active_idx    on client_packages (org_id, user_id, status, purchased_at);

-- LEDGER UNIFICATO: unica fonte del fatturato reale
create table payments (
    id                   uuid primary key default gen_random_uuid(),
    org_id               uuid not null references organizations(id) on delete cascade,
    created_at           timestamptz not null default now(),
    client_user_id       uuid references profiles(id) on delete set null,
    client_email         text,
    amount               numeric(10,2) not null,
    currency             text not null default 'EUR',
    method               text not null
                         check (method in ('contanti','contanti-report','carta','iban','stripe','gratuito')),
    kind                 text not null
                         check (kind in ('session','membership','package_purchase','penalty_mora','adjustment','account_credit')),
    booking_id           uuid references bookings(id) on delete set null,
    membership_id        uuid references client_memberships(id) on delete set null,
    package_id           uuid references client_packages(id) on delete set null,
    period_start         date,
    period_end           date,
    note                 text,
    created_by           uuid,
    stripe_payment_intent text unique
);
create index payments_org_created_idx on payments (org_id, created_at);
create index payments_org_email_idx   on payments (org_id, client_email);
-- idempotenza: un booking-sessione non genera due righe 'session'
create unique index payments_booking_session_uidx on payments (booking_id) where kind = 'session';

-- CONTO CLIENTE A ENTRATA: append-only, positivo=credito e negativo=debito.
-- Gli addebiti lezione vengono inseriti server-side all'orario di inizio.
create table client_balance_entries (
    id              uuid primary key default gen_random_uuid(),
    org_id          uuid not null references organizations(id) on delete cascade,
    user_id         uuid not null references profiles(id) on delete cascade,
    booking_id      uuid references bookings(id) on delete set null,
    payment_id      uuid references payments(id) on delete set null,
    kind            text not null check (kind in ('lesson_charge','lesson_reversal','booking_payment',
                        'lesson_waiver','waiver_reversal','manual_credit','manual_debt','manual_payment','model_reset')),
    amount          numeric(12,2) not null,
    note            text,
    effective_at    timestamptz not null default now(),
    created_at      timestamptz not null default now(),
    created_by      uuid references auth.users(id) on delete set null,
    idempotency_key text not null,
    unique (org_id,idempotency_key)
);
create index client_balance_entries_org_user_idx
    on client_balance_entries (org_id,user_id,effective_at desc);
create unique index client_balance_entries_payment_uidx
    on client_balance_entries(payment_id) where payment_id is not null;
create unique index client_balance_entries_booking_charge_uidx
    on client_balance_entries(booking_id) where kind='lesson_charge' and booking_id is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 6 — BILLING-SaaS (il trainer paga la piattaforma)
-- ─────────────────────────────────────────────────────────────────────────────

create table plans (
    id                    uuid primary key default gen_random_uuid(),
    code                  text not null unique,              -- starter|pro|business
    name                  text not null,
    stripe_price_id_monthly text,
    price_eur             numeric(10,2) not null,
    max_clients           integer,                           -- null = illimitato
    features              jsonb not null default '{}'::jsonb,
    sort_order            integer not null default 0,
    active                boolean not null default true
);

create table subscriptions (
    id                     uuid primary key default gen_random_uuid(),
    org_id                 uuid not null unique references organizations(id) on delete cascade,
    plan_id                uuid references plans(id),
    stripe_customer_id     text,
    stripe_subscription_id text unique,
    status                 text not null default 'trialing'
                           check (status in ('trialing','active','past_due','canceled','unpaid','incomplete')),
    current_period_end     timestamptz,
    cancel_at_period_end   boolean not null default false,
    trial_end              timestamptz,
    created_at             timestamptz not null default now(),
    updated_at             timestamptz not null default now()
);
create index subscriptions_org_idx on subscriptions (org_id);

create table subscription_events (
    id              uuid primary key default gen_random_uuid(),
    org_id          uuid references organizations(id) on delete cascade,
    stripe_event_id text not null unique,                    -- idempotenza webhook
    type            text not null,
    payload         jsonb,
    created_at      timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 7 — SETTINGS per-org
-- ─────────────────────────────────────────────────────────────────────────────

create table org_settings (
    org_id      uuid not null references organizations(id) on delete cascade,
    key         text not null,
    value       jsonb not null default 'null'::jsonb,
    updated_at  timestamptz not null default now(),
    updated_by  uuid references auth.users(id) on delete set null,
    primary key (org_id, key)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 8 — WORKOUT (tenant-aware)
-- ─────────────────────────────────────────────────────────────────────────────

create table workout_plans (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade default current_org_id(),  -- default: l'INSERT del frontend (WorkoutPlanStorage) non passa org_id
    user_id     uuid not null references profiles(id) on delete cascade,
    name        text not null,
    start_date  date,
    end_date    date,
    notes       text,
    active      boolean not null default true,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
create index workout_plans_org_user_idx on workout_plans (org_id, user_id, active);

create table workout_exercises (
    id             uuid primary key default gen_random_uuid(),
    org_id         uuid not null references organizations(id) on delete cascade default current_org_id(),  -- default: l'INSERT del frontend non passa org_id
    plan_id        uuid not null references workout_plans(id) on delete cascade,
    day_label      text not null default 'Giorno A',
    exercise_name  text not null,
    exercise_slug  text,
    muscle_group   text,
    sort_order     integer not null default 0,
    sets           integer not null default 3,
    reps           text not null default '10',
    weight_kg      numeric(6,1),
    rest_seconds   integer default 90,
    superset_group uuid,
    circuit_group  uuid,
    notes          text
);
create index workout_exercises_plan_idx on workout_exercises (plan_id, sort_order);

create table workout_logs (
    id           uuid primary key default gen_random_uuid(),
    org_id       uuid not null references organizations(id) on delete cascade default current_org_id(),  -- default: l'INSERT del frontend (WorkoutLogStorage) non passa org_id
    exercise_id  uuid not null references workout_exercises(id) on delete cascade,
    user_id      uuid not null references profiles(id) on delete cascade,
    log_date     date not null default current_date,
    set_number   integer not null,
    reps_done    integer,
    weight_done  numeric(6,1),
    rest_done    integer,
    rpe          integer check (rpe is null or (rpe between 1 and 10)),
    notes        text,
    created_at   timestamptz not null default now(),
    unique (exercise_id, user_id, log_date, set_number)
);
create index workout_logs_ex_date_idx on workout_logs (exercise_id, log_date);
create index workout_logs_user_idx    on workout_logs (user_id);

-- Schema allineato al frontend (admin-importa.js / admin-schede.js / allenamento.html
-- / tablet.html): l'admin importa nel proprio tenant un sottoinsieme del catalogo
-- completo (data/esercizi_completo.json). org_id default = current_org_id() cosi'
-- l'INSERT del frontend (che non passa org_id) supera la policy di scrittura.
create table imported_exercises (
    id                  uuid primary key default gen_random_uuid(),
    org_id              uuid references organizations(id) on delete cascade default current_org_id(),  -- null = catalogo globale piattaforma
    slug                text,
    nome_it             text,
    nome_original       text,
    nome_en             text,
    categoria           text,
    immagine            text,
    immagine_thumbnail  text,
    video               text,
    popolarita          integer default 0,
    data                jsonb
);
create index imported_exercises_org_slug_idx on imported_exercises (org_id, slug);

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO 9 — NOTIFICHE / REPORT
-- ─────────────────────────────────────────────────────────────────────────────

create table push_subscriptions (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    user_id     uuid not null references auth.users(id) on delete cascade,
    endpoint    text not null,
    p256dh      text,
    auth        text,
    created_at  timestamptz not null default now(),
    unique (endpoint)
);
create index push_subscriptions_org_user_idx on push_subscriptions (org_id, user_id);

create table client_notifications (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    user_id     uuid references profiles(id) on delete cascade,
    title       text,
    body        text,
    read        boolean not null default false,
    created_at  timestamptz not null default now()
);
create index client_notifications_org_user_idx on client_notifications (org_id, user_id);

create table admin_messages (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    kind        text,
    title       text,
    body        text,
    read        boolean not null default false,
    created_at  timestamptz not null default now()
);
create index admin_messages_org_idx on admin_messages (org_id, created_at);

create table monthly_reports (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    user_id     uuid references profiles(id) on delete cascade,
    month       text not null,
    tone        text,
    content     text,
    created_at  timestamptz not null default now()
);
create index monthly_reports_org_idx on monthly_reports (org_id, user_id, month);

create table login_events (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid references organizations(id) on delete cascade,
    user_id     uuid references auth.users(id) on delete set null,
    event       text,
    created_at  timestamptz not null default now()
);
create index login_events_org_idx on login_events (org_id, created_at);

-- ══════════════════════════════════════════════════════════════════════════════
-- BLOCCO 10 — RLS (pattern uniforme org-scoped). Nessuna policy USING(true).
-- ══════════════════════════════════════════════════════════════════════════════

-- helper: applica RLS standard "admin tutto, cliente i propri" via DO block
alter table organizations          enable row level security;
alter table org_members            enable row level security;
alter table profiles               enable row level security;
alter table bookings               enable row level security;
alter table slot_types             enable row level security;
alter table time_slots_config      enable row level security;
alter table weekly_schedule_templates enable row level security;
alter table weekly_template_slots  enable row level security;
alter table schedule_overrides     enable row level security;
alter table billing_settings       enable row level security;
alter table client_billing_profiles enable row level security;
alter table client_memberships     enable row level security;
alter table client_packages        enable row level security;
alter table payments               enable row level security;
alter table client_balance_entries enable row level security;
alter table plans                  enable row level security;
alter table subscriptions          enable row level security;
alter table subscription_events    enable row level security;
alter table org_settings           enable row level security;
alter table workout_plans          enable row level security;
alter table workout_exercises      enable row level security;
alter table workout_logs           enable row level security;
alter table imported_exercises     enable row level security;
alter table push_subscriptions     enable row level security;
alter table client_notifications   enable row level security;
alter table admin_messages         enable row level security;
alter table monthly_reports        enable row level security;
alter table login_events           enable row level security;

-- organizations: i membri vedono la propria org; aggiorna solo owner/admin
create policy organizations_member_read on organizations
    for select to authenticated
    using (id = current_org_id());
create policy organizations_admin_write on organizations
    for update to authenticated
    using (is_org_admin(id)) with check (is_org_admin(id));

-- org_members: i membri vedono la propria org; gestione owner/admin
create policy org_members_read on org_members
    for select to authenticated
    using (org_id = current_org_id());
create policy org_members_admin_all on org_members
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

-- profiles: cliente vede sé stesso; admin vede tutta la org
create policy profiles_select on profiles
    for select to authenticated
    using (org_id = current_org_id() and (id = auth.uid() or is_org_admin(org_id)));
create policy profiles_insert on profiles
    for insert to authenticated
    with check (org_id = current_org_id() and (id = auth.uid() or is_org_admin(org_id)));
create policy profiles_update on profiles
    for update to authenticated
    using (org_id = current_org_id() and (id = auth.uid() or is_org_admin(org_id)))
    with check (org_id = current_org_id() and (id = auth.uid() or is_org_admin(org_id)));
create policy profiles_admin_delete on profiles
    for delete to authenticated
    using (org_id = current_org_id() and is_org_admin(org_id));

-- bookings: cliente vede i propri; admin tutta la org. Insert via RPC (vedi sotto).
create policy bookings_select on bookings
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy bookings_admin_write on bookings
    for all to authenticated
    using (org_id = current_org_id() and is_org_admin(org_id))
    with check (org_id = current_org_id() and is_org_admin(org_id));

-- catalogo orari: lettura a tutti i membri della org, scrittura admin
create policy slot_types_read on slot_types
    for select to authenticated using (org_id = current_org_id());
create policy slot_types_admin on slot_types
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy time_slots_read on time_slots_config
    for select to authenticated using (org_id = current_org_id());
create policy time_slots_admin on time_slots_config
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy templates_read on weekly_schedule_templates
    for select to authenticated using (org_id = current_org_id());
create policy templates_admin on weekly_schedule_templates
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy template_slots_read on weekly_template_slots
    for select to authenticated using (org_id = current_org_id());
create policy template_slots_admin on weekly_template_slots
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy overrides_read on schedule_overrides
    for select to authenticated using (org_id = current_org_id());
create policy overrides_admin on schedule_overrides
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

-- billing-cliente: cliente legge i propri record; admin gestisce
create policy billing_settings_read on billing_settings
    for select to authenticated using (org_id = current_org_id());
create policy billing_settings_admin on billing_settings
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy client_billing_profiles_select on client_billing_profiles
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy client_billing_profiles_admin on client_billing_profiles
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy memberships_select on client_memberships
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy memberships_admin on client_memberships
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy packages_select on client_packages
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy packages_admin on client_packages
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy payments_select on payments
    for select to authenticated
    using (org_id = current_org_id() and (client_user_id = auth.uid() or is_org_admin(org_id)));
create policy payments_admin on payments
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy client_balance_entries_select on client_balance_entries
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));

-- plans: catalogo pubblico in lettura (serve in pagina pricing/upgrade)
create policy plans_read on plans for select to authenticated using (true);

-- subscriptions / events: solo membri/admin della org
create policy subscriptions_read on subscriptions
    for select to authenticated using (org_id = current_org_id());
create policy subscription_events_admin on subscription_events
    for select to authenticated using (org_id = current_org_id() and is_org_admin(org_id));
-- scritture su subscriptions/events: solo service_role (webhook) → nessuna policy per authenticated

-- org_settings: lettura membri org; scrittura admin (preferire RPC upsert_org_setting)
create policy org_settings_read on org_settings
    for select to authenticated using (org_id = current_org_id());
create policy org_settings_admin on org_settings
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

-- workout
create policy workout_plans_select on workout_plans
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy workout_plans_admin on workout_plans
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy workout_exercises_select on workout_exercises
    for select to authenticated
    using (org_id = current_org_id() and (
        is_org_admin(org_id) or plan_id in (select id from workout_plans where user_id = auth.uid())));
create policy workout_exercises_admin on workout_exercises
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy workout_logs_select on workout_logs
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy workout_logs_own_write on workout_logs
    for all to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)))
    with check (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));

create policy imported_exercises_read on imported_exercises
    for select to authenticated
    using (org_id is null or org_id = current_org_id());
create policy imported_exercises_admin on imported_exercises
    for all to authenticated
    using (org_id = current_org_id() and is_org_admin(org_id))
    with check (org_id = current_org_id() and is_org_admin(org_id));

-- notifiche
create policy push_subscriptions_own on push_subscriptions
    for all to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)))
    with check (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));

create policy client_notifications_select on client_notifications
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy client_notifications_admin on client_notifications
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy admin_messages_admin on admin_messages
    for all to authenticated
    using (org_id = current_org_id() and is_org_admin(org_id))
    with check (org_id = current_org_id() and is_org_admin(org_id));

create policy monthly_reports_select on monthly_reports
    for select to authenticated
    using (org_id = current_org_id() and (user_id = auth.uid() or is_org_admin(org_id)));
create policy monthly_reports_admin on monthly_reports
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

create policy login_events_admin on login_events
    for select to authenticated
    using (org_id = current_org_id() and is_org_admin(org_id));

-- ══════════════════════════════════════════════════════════════════════════════
-- BLOCCO 11 — RPC core org-scoped
-- ══════════════════════════════════════════════════════════════════════════════

-- listino prezzo effettivo per slot_type (server-authoritative)
create or replace function get_org_price(p_org_id uuid, p_slot_type text)
returns numeric language sql stable security definer set search_path = public as $$
    select coalesce(
        (select default_price from slot_types where org_id = p_org_id and key = p_slot_type and is_active),
        0
    )
$$;

-- risolve tipo-slot e capienza effettiva: override → template attivo → default
create or replace function resolve_slot_config(p_org_id uuid, p_date date, p_time text)
returns table(slot_type text, slot_type_id uuid, capacity integer, price numeric, bookable boolean)
language plpgsql stable security definer set search_path = public as $$
declare
    v_ovr        schedule_overrides%rowtype;
    v_ts_id      uuid;
    v_tpl_id     uuid;
    v_weekday    smallint := extract(dow from p_date)::smallint;  -- 0=Domenica
    v_st_id      uuid;
    v_cap        integer;
begin
    -- 1) override per data
    select * into v_ovr from schedule_overrides
        where org_id = p_org_id and date = p_date and time = p_time;
    if found then
        select st.key, st.id, coalesce(v_ovr.capacity, st.default_capacity), st.default_price, st.bookable
            into slot_type, slot_type_id, capacity, price, bookable
            from slot_types st where st.id = v_ovr.slot_type_id;
        if not found then
            slot_type := v_ovr.slot_type; slot_type_id := null;
            capacity  := coalesce(v_ovr.capacity, 0); price := 0; bookable := true;
        end if;
        return next; return;
    end if;

    -- 2) template settimanale attivo
    select id into v_tpl_id from weekly_schedule_templates
        where org_id = p_org_id and is_active order by created_at desc limit 1;
    select id into v_ts_id from time_slots_config
        where org_id = p_org_id
          and (to_char(start_time, 'HH24:MI') || ' - ' || to_char(end_time, 'HH24:MI')) = p_time
        limit 1;
    if v_tpl_id is not null and v_ts_id is not null then
        select wts.slot_type_id, coalesce(wts.capacity, st.default_capacity)
            into v_st_id, v_cap
            from weekly_template_slots wts
            join slot_types st on st.id = wts.slot_type_id
            where wts.template_id = v_tpl_id and wts.weekday = v_weekday and wts.time_slot_id = v_ts_id;
        if found then
            select st.key, st.id, v_cap, st.default_price, st.bookable
                into slot_type, slot_type_id, capacity, price, bookable
                from slot_types st where st.id = v_st_id;
            return next; return;
        end if;
    end if;

    -- 3) niente configurato → slot non prenotabile
    slot_type := null; slot_type_id := null; capacity := 0; price := 0; bookable := false;
    return next;
end;
$$;

-- prenotazione server-authoritative: capienza dal DB, gating billing-cliente.
-- p_org_slug per i client anonimi (nessun JWT); per gli autenticati si usa current_org_id().
create or replace function book_slot(
    p_org_slug   text,
    p_local_id   text,
    p_date       text,
    p_time       text,
    p_name       text,
    p_email      text,
    p_whatsapp   text,
    p_notes      text,
    p_date_display text default '',
    p_for_user_id uuid default null   -- admin: prenota per conto di un cliente
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org        uuid;
    v_uid        uuid := auth.uid();
    v_book_user  uuid;
    v_email      text := lower(trim(coalesce(p_email, '')));
    v_cfg        record;
    v_count      integer;
    v_id         uuid;
    v_is_admin   boolean := false;
    v_start_time time;
    v_lesson_dt  timestamptz;
    v_tz         text;
    v_model      text;
    v_pkg        client_packages%rowtype;
    v_mem        client_memberships%rowtype;
    v_pkg_id     uuid := null;   -- pacchetto effettivamente decrementato (per refund su cancel)
    v_mem_id     uuid := null;   -- membership la cui quota è stata consumata (per refund su cancel)
    v_paid       boolean := false;
    v_method     text := null;
begin
    -- risolvi org: slug (anon/pubblico) oppure org del chiamante
    v_org := coalesce(org_id_for_slug(p_org_slug), current_org_id());
    if v_org is null then
        return jsonb_build_object('success', false, 'error', 'org_not_found');
    end if;
    v_is_admin := is_org_admin(v_org);
    select timezone into v_tz from organizations where id = v_org;
    v_tz := coalesce(v_tz, 'Europe/Rome');

    -- A chi attribuire il booking (bookings.user_id → profiles, può essere NULL):
    --  - admin che prenota per un cliente (p_for_user_id, deve essere profilo della org)
    --  - altrimenti il chiamante, se è un profilo cliente della org
    --  - altrimenti NULL (anonimo, o admin/staff senza profilo cliente → niente FK error)
    if p_for_user_id is not null and v_is_admin
       and exists (select 1 from profiles where id = p_for_user_id and org_id = v_org) then
        v_book_user := p_for_user_id;
    elsif v_uid is not null
       and exists (select 1 from profiles where id = v_uid and org_id = v_org) then
        v_book_user := v_uid;
    else
        v_book_user := null;
    end if;

    if v_email <> '' and v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' then
        return jsonb_build_object('success', false, 'error', 'invalid_email');
    end if;
    if p_name is null or trim(p_name) = '' then
        return jsonb_build_object('success', false, 'error', 'missing_name');
    end if;
    if p_date::date < current_date and not v_is_admin then
        return jsonb_build_object('success', false, 'error', 'past_date');
    end if;

    -- config slot (capienza/prezzo) server-side
    select * into v_cfg from resolve_slot_config(v_org, p_date::date, p_time);
    if not coalesce(v_cfg.bookable, false) or coalesce(v_cfg.capacity, 0) <= 0 then
        return jsonb_build_object('success', false, 'error', 'not_bookable');
    end if;

    -- cutoff troppo tardi (solo non-admin)
    if not v_is_admin then
        v_start_time := split_part(p_time, ' - ', 1)::time;
        v_lesson_dt  := (p_date::date + v_start_time) at time zone v_tz;
        if now() > v_lesson_dt + interval '30 minutes' then
            return jsonb_build_object('success', false, 'error', 'too_late');
        end if;
    end if;

    -- advisory lock anti-overbooking (include org_id)
    if not pg_try_advisory_xact_lock(hashtext(v_org::text || '|' || p_date || '|' || p_time || '|' || v_cfg.slot_type)) then
        return jsonb_build_object('success', false, 'error', 'slot_busy');
    end if;

    select count(*) into v_count from bookings
        where org_id = v_org and date = p_date::date and time = p_time
          and slot_type = v_cfg.slot_type
          and status in ('confirmed','cancellation_requested');
    if v_count >= v_cfg.capacity then
        return jsonb_build_object('success', false, 'error', 'slot_full');
    end if;

    -- gating/decremento billing-cliente (solo se cliente identificato)
    if v_book_user is not null then
        select coalesce(cbp.model_override, bs.default_model, 'pay_per_session')
            into v_model
            from billing_settings bs
            left join client_billing_profiles cbp
                   on cbp.org_id = v_org and cbp.user_id = v_book_user
            where bs.org_id = v_org;
        v_model := coalesce(v_model, 'pay_per_session');

        if v_model = 'free' then
            v_paid := true; v_method := 'gratuito';
        elsif v_model = 'package' then
            select * into v_pkg from client_packages
                where org_id = v_org and user_id = v_book_user and status = 'active'
                  and remaining_sessions > 0 and (expires_at is null or expires_at >= current_date)
                order by purchased_at asc limit 1 for update;
            if not found then
                if (select block_if_no_package from billing_settings where org_id = v_org) then
                    return jsonb_build_object('success', false, 'error', 'no_package');
                end if;
            else
                update client_packages set remaining_sessions = remaining_sessions - 1,
                    status = case when remaining_sessions - 1 <= 0 then 'exhausted' else status end
                    where id = v_pkg.id;
                v_pkg_id := v_pkg.id;
                v_paid := true; v_method := 'pacchetto';
            end if;
        elsif v_model = 'monthly' then
            select * into v_mem from client_memberships
                where org_id = v_org and user_id = v_book_user and status = 'active'
                order by period_end desc limit 1 for update;
            if not found or v_mem.period_end < (current_date - make_interval(days => coalesce((select grace_days from billing_settings where org_id = v_org),0))) then
                if (select block_if_membership_expired from billing_settings where org_id = v_org) then
                    return jsonb_build_object('success', false, 'error', 'membership_expired');
                end if;
            elsif v_mem.lessons_quota is not null and v_mem.lessons_used >= v_mem.lessons_quota then
                return jsonb_build_object('success', false, 'error', 'quota_exceeded');
            else
                update client_memberships set lessons_used = lessons_used + 1 where id = v_mem.id;
                v_mem_id := v_mem.id;
                v_paid := true; v_method := 'abbonamento';
            end if;
        end if;
        -- pay_per_session: paid=false, saldo via admin_pay_bookings
    end if;

    insert into bookings (org_id, local_id, user_id, date, time, slot_type, slot_type_id,
        name, email, whatsapp, notes, status, created_at, date_display, created_by,
        paid, payment_method, paid_at, consumed_package_id, consumed_membership_id)
    values (v_org, p_local_id, v_book_user, p_date::date, p_time, v_cfg.slot_type, v_cfg.slot_type_id,
        trim(p_name), nullif(v_email,''), nullif(trim(coalesce(p_whatsapp,'')),''), p_notes,
        'confirmed', now(), p_date_display, v_uid,
        v_paid, v_method, case when v_paid then now() else null end, v_pkg_id, v_mem_id)
    returning id into v_id;

    return jsonb_build_object('success', true, 'booking_id', v_id::text, 'paid', v_paid);
exception
    when unique_violation then
        return jsonb_build_object('success', false, 'error', 'duplicate_booking');
end;
$$;
revoke all on function book_slot from public;
grant execute on function book_slot to anon, authenticated;

-- segna prenotazioni come pagate + registra nel ledger (niente credito)
create or replace function admin_pay_bookings(
    p_booking_ids uuid[],
    p_method      text,
    p_paid_at     timestamptz default now()
) returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_org   uuid := current_org_id();
    v_b     bookings%rowtype;
    v_price numeric(10,2);
    v_count integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;

    for v_b in select * from bookings
        where id = any(p_booking_ids) and org_id = v_org for update
    loop
        update bookings set paid = true, payment_method = p_method, paid_at = p_paid_at
            where id = v_b.id and not paid;
        if found then
            -- Lezione regalata: importo 0 e metodo 'gratuito' (escluso dal fatturato in
            -- admin-analytics). Senza questo ramo cadrebbe in 'contanti' a prezzo pieno,
            -- gonfiando l'incasso con denaro mai ricevuto.
            v_price := case when p_method = 'gratuito'
                            then 0
                            else coalesce(v_b.custom_price, get_org_price(v_org, v_b.slot_type)) end;
            insert into payments (org_id, client_user_id, client_email, amount, currency,
                method, kind, booking_id, created_by)
            values (v_org, v_b.user_id, v_b.email, v_price,
                (select currency from organizations where id = v_org),
                case when p_method in ('contanti','contanti-report','carta','iban','stripe','gratuito') then p_method else 'contanti' end,
                'session', v_b.id, auth.uid())
            on conflict (booking_id) where kind = 'session' do nothing;
            v_count := v_count + 1;
        end if;
    end loop;
    return v_count;
end;
$$;
revoke all on function admin_pay_bookings from public;
grant execute on function admin_pay_bookings to authenticated;

-- vende un pacchetto al cliente + registra incasso
create or replace function admin_sell_package(
    p_user_id uuid, p_label text, p_sessions integer, p_price numeric,
    p_method text default 'contanti', p_expires date default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_pkg uuid; v_email text;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    select email into v_email from profiles where id = p_user_id and org_id = v_org;
    insert into client_packages (org_id, user_id, label, total_sessions, remaining_sessions, expires_at, price)
        values (v_org, p_user_id, p_label, p_sessions, p_sessions, p_expires, p_price)
        returning id into v_pkg;
    insert into payments (org_id, client_user_id, client_email, amount, method, kind, package_id, created_by)
        values (v_org, p_user_id, v_email, p_price, p_method, 'package_purchase', v_pkg, auth.uid());
    return v_pkg;
end;
$$;
revoke all on function admin_sell_package from public;
grant execute on function admin_sell_package to authenticated;

-- registra il pagamento di una quota mensile (crea/estende membership)
create or replace function admin_record_membership_payment(
    p_user_id uuid, p_label text, p_price numeric, p_period_start date, p_period_end date,
    p_lessons_quota integer default null, p_method text default 'contanti'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_mem uuid; v_email text;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    select email into v_email from profiles where id = p_user_id and org_id = v_org;
    insert into client_memberships (org_id, user_id, plan_label, period_start, period_end, lessons_quota, price, status)
        values (v_org, p_user_id, p_label, p_period_start, p_period_end, p_lessons_quota, p_price, 'active')
        returning id into v_mem;
    insert into payments (org_id, client_user_id, client_email, amount, method, kind, membership_id,
        period_start, period_end, created_by)
        values (v_org, p_user_id, v_email, p_price, p_method, 'membership', v_mem,
            p_period_start, p_period_end, auth.uid());
    return v_mem;
end;
$$;
revoke all on function admin_record_membership_payment from public;
grant execute on function admin_record_membership_payment to authenticated;

-- onboarding: crea organizzazione + membership owner + settings di default
create or replace function create_organization(p_name text, p_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_slug text := lower(trim(p_slug));
begin
    if auth.uid() is null then raise exception 'not_authenticated'; end if;
    if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then raise exception 'invalid_slug'; end if;
    if exists (select 1 from organizations where slug = v_slug) then raise exception 'slug_taken'; end if;

    insert into organizations (name, slug, owner_user_id, status)
        values (trim(p_name), v_slug, auth.uid(), 'trialing') returning id into v_org;
    insert into org_members (org_id, user_id, role) values (v_org, auth.uid(), 'owner');

    -- billing-cliente default
    insert into billing_settings (org_id) values (v_org);

    -- subscription trial 30gg sul piano starter (se presente)
    insert into subscriptions (org_id, plan_id, status, trial_end)
        values (v_org, (select id from plans where code = 'starter' limit 1),
                'trialing', now() + interval '30 days');

    -- slot types di default
    insert into slot_types (org_id, key, label, color, default_capacity, default_price, sort_order) values
        (v_org, 'personal-training', 'Personal Training', '#8B5CF6', 1, 0, 0),
        (v_org, 'small-group',       'Small Group',        '#22C55E', 5, 0, 1),
        (v_org, 'group-class',       'Group Class',        '#F59E0B', 12, 0, 2);

    -- settings di base
    insert into org_settings (org_id, key, value) values
        (v_org, 'branding.studio_name', to_jsonb(trim(p_name))),
        (v_org, 'branding.primary_color', to_jsonb('#8B5CF6'::text)),
        (v_org, 'locale.timezone', to_jsonb('Europe/Rome'::text)),
        (v_org, 'locale.currency', to_jsonb('EUR'::text)),
        (v_org, 'booking.policy.free_cancel_hours', to_jsonb(24)),
        (v_org, 'booking.policy.penalty_pct', to_jsonb(50))
    on conflict do nothing;

    return v_org;
end;
$$;
revoke all on function create_organization from public;
grant execute on function create_organization to authenticated;

-- upsert di una impostazione (verifica org admin)
create or replace function upsert_org_setting(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    insert into org_settings (org_id, key, value, updated_at, updated_by)
        values (v_org, p_key, p_value, now(), auth.uid())
        on conflict (org_id, key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end;
$$;
revoke all on function upsert_org_setting from public;
grant execute on function upsert_org_setting to authenticated;

-- settings pubbliche per client anonimi (whitelist: niente dati sensibili)
create or replace function get_public_org_settings(p_org_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from org_settings
    where org_id = org_id_for_slug(p_org_slug)
      and key like any (array['branding.%','locale.%','booking.policy.%','billing_client.prices%','maintenance.%']);
$$;
grant execute on function get_public_org_settings to anon, authenticated;

-- entitlements del tenant (piano, limiti, stato) per il feature gating
create or replace function get_tenant_entitlements()
returns jsonb language sql stable security definer set search_path = public as $$
    select jsonb_build_object(
        'plan',        p.code,
        'status',      s.status,
        'max_clients', p.max_clients,
        'features',    coalesce(p.features, '{}'::jsonb),
        'trial_end',   s.trial_end,
        'current_period_end', s.current_period_end,
        'clients_count', (select count(*) from profiles where org_id = current_org_id())
    )
    from subscriptions s
    left join plans p on p.id = s.plan_id
    where s.org_id = current_org_id()
$$;
grant execute on function get_tenant_entitlements to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- BLOCCO 12 — TRIGGER updated_at
-- ══════════════════════════════════════════════════════════════════════════════
create or replace function trg_set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
create trigger organizations_updated_at before update on organizations
    for each row execute function trg_set_updated_at();
create trigger workout_plans_updated_at before update on workout_plans
    for each row execute function trg_set_updated_at();
create trigger subscriptions_updated_at before update on subscriptions
    for each row execute function trg_set_updated_at();
create trigger bookings_updated_at before update on bookings
    for each row execute function trg_set_updated_at();

-- ══════════════════════════════════════════════════════════════════════════════
-- BLOCCO 12b — ONBOARDING: handle_new_user (multi-tenant) + join_organization
-- ══════════════════════════════════════════════════════════════════════════════

-- Alla creazione di un auth.user:
--  - signup_type='trainer'  → nessun profilo cliente (l'org la crea create_organization)
--  - org_slug presente      → crea profiles nella org risolta + collega bookings anonimi
--  - altrimenti             → nessun profilo (verrà creato da join_organization)
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
    v_signup_type text := coalesce(new.raw_user_meta_data->>'signup_type', 'client');
    v_org_slug    text := nullif(trim(coalesce(new.raw_user_meta_data->>'org_slug','')), '');
    v_org         uuid;
    v_name        text := coalesce(
        nullif(trim(new.raw_user_meta_data->>'full_name'),''),
        nullif(trim(new.raw_user_meta_data->>'name'),''),
        split_part(new.email,'@',1));
    v_email       text := lower(trim(new.email));
begin
    if v_signup_type = 'trainer' then return new; end if;
    if v_org_slug is null then return new; end if;
    v_org := org_id_for_slug(v_org_slug);
    if v_org is null then return new; end if;

    insert into profiles (id, org_id, name, email, whatsapp,
        codice_fiscale, indirizzo_via, indirizzo_paese, indirizzo_cap)
    values (new.id, v_org, v_name, v_email,
        coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'whatsapp','')),''), ''),
        upper(nullif(trim(coalesce(new.raw_user_meta_data->>'codice_fiscale','')),'')),
        nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_via','')),''),
        nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_paese','')),''),
        nullif(trim(coalesce(new.raw_user_meta_data->>'indirizzo_cap','')),''))
    on conflict (id) do nothing;

    update bookings set user_id = new.id
        where org_id = v_org and lower(email) = v_email and user_id is null;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure handle_new_user();

-- Un utente autenticato si associa come cliente a una org (via slug pubblico).
create or replace function join_organization(p_org_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_uid uuid := auth.uid(); v_email text; v_name text;
begin
    if v_uid is null then raise exception 'not_authenticated'; end if;
    v_org := org_id_for_slug(p_org_slug);
    if v_org is null then raise exception 'org_not_found'; end if;

    -- Enforcement limite clienti del piano: blocca il signup self-serve oltre soglia.
    -- (NULL/false = nessun limite; non blocca l'utente già membro perché ON CONFLICT
    --  DO NOTHING gestisce comunque l'idempotenza a valle.)
    if org_at_client_limit(v_org) then raise exception 'client_limit_reached'; end if;

    select lower(u.email), coalesce(u.raw_user_meta_data->>'full_name', split_part(u.email,'@',1))
        into v_email, v_name from auth.users u where u.id = v_uid;

    insert into profiles (id, org_id, name, email)
        values (v_uid, v_org, v_name, v_email)
        on conflict (id) do nothing;

    update bookings set user_id = v_uid
        where org_id = v_org and lower(email) = v_email and user_id is null;

    return v_org;
end;
$$;
revoke all on function join_organization from public;
grant execute on function join_organization to authenticated;

-- Invita un membro staff (owner/admin). Crea una riga 'invited' collegata via email
-- al primo accesso del membro (gestito lato app).
create or replace function invite_org_member(p_email text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    if p_role not in ('admin','staff') then raise exception 'invalid_role'; end if;
    insert into org_members (org_id, user_id, role, status, invited_email)
        select v_org, u.id, p_role, 'active', lower(trim(p_email))
        from auth.users u where lower(u.email) = lower(trim(p_email))
        on conflict (org_id, user_id) do update set role = excluded.role, status = 'active';
    -- se l'utente non esiste ancora, lasciamo traccia dell'invito (status invited, user_id placeholder gestito app-side)
end;
$$;
revoke all on function invite_org_member from public;
grant execute on function invite_org_member to authenticated;

-- ══════════════════════════════════════════════════════════════════════════════
-- BLOCCO 13 — SEED PIANI SaaS (3 tier + trial). I price_id Stripe si impostano
-- dopo aver creato i prodotti su Stripe (UPDATE plans SET stripe_price_id_monthly=...).
-- ══════════════════════════════════════════════════════════════════════════════
insert into plans (code, name, price_eur, max_clients, sort_order, features) values
    ('starter',  'Starter',  39.99, 50,   0, '{"workout_plans":true,"messaging":true,"ai_reports":false,"client_online_payments":false}'::jsonb),
    ('pro',      'Pro',      79.99, 200,  1, '{"workout_plans":true,"messaging":true,"ai_reports":true,"client_online_payments":true}'::jsonb),
    ('business', 'Business', 149.99, null, 2, '{"workout_plans":true,"messaging":true,"ai_reports":true,"client_online_payments":true}'::jsonb)
on conflict (code) do nothing;
