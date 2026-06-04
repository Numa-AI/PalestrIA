-- PalestrIA — Schema iniziale (idempotente)

create table if not exists bookings (
    id              uuid primary key default gen_random_uuid(),
    created_at      timestamptz not null default now(),
    date            date not null,
    time            text not null,
    slot_type       text not null,
    name            text not null,
    email           text not null,
    whatsapp        text,
    notes           text,
    status          text not null default 'confirmed',
    paid            boolean not null default false,
    payment_method  text,
    paid_at         timestamptz
);

create index if not exists bookings_date_idx      on bookings (date);
create index if not exists bookings_email_idx     on bookings (email);
create index if not exists bookings_date_time_idx on bookings (date, time);

create table if not exists schedule_overrides (
    id          uuid primary key default gen_random_uuid(),
    created_at  timestamptz not null default now(),
    date        date not null,
    time        text not null,
    slot_type   text,
    unique (date, time)
);

create table if not exists credits (
    id          uuid primary key default gen_random_uuid(),
    created_at  timestamptz not null default now(),
    name        text not null,
    whatsapp    text,
    email       text not null,
    balance     numeric(10,2) not null default 0,
    unique (email)
);

create table if not exists credit_history (
    id          uuid primary key default gen_random_uuid(),
    created_at  timestamptz not null default now(),
    credit_id   uuid not null references credits(id) on delete cascade,
    amount      numeric(10,2) not null,
    note        text
);

-- ─── RLS ─────────────────────────────────────────────────────────────────────
alter table bookings           enable row level security;
alter table schedule_overrides enable row level security;
alter table credits            enable row level security;
alter table credit_history     enable row level security;

drop policy if exists "schedule_overrides_public_read" on schedule_overrides;
create policy "schedule_overrides_public_read"
    on schedule_overrides for select using (true);

drop policy if exists "bookings_public_read" on bookings;
create policy "bookings_public_read"
    on bookings for select using (true);

drop policy if exists "bookings_public_insert" on bookings;
create policy "bookings_public_insert"
    on bookings for insert with check (true);
