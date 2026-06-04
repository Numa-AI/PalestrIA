-- ─── login_events: traccia login e dispositivi ──────────────────────────────
-- Ogni volta che un utente esegue un login esplicito (password o signup),
-- il client scrive un record qui. Permette all'admin di vedere accessi recenti
-- e dispositivi distinti per ciascun utente.

create table if not exists login_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    event_type text not null default 'login',   -- 'login' | 'signup'
    device_hash text,                            -- sha256(ua + screen + tz + lang)
    user_agent text,
    platform text,                               -- 'ios' | 'android' | 'windows' | 'mac' | 'linux' | 'other'
    browser text,                                -- 'chrome' | 'safari' | 'firefox' | 'edge' | 'opera' | 'other'
    screen_size text,                            -- "1920x1080"
    timezone text,
    language text,
    is_pwa boolean default false,
    created_at timestamptz not null default now()
);

create index if not exists login_events_user_created_idx
    on login_events(user_id, created_at desc);
create index if not exists login_events_device_idx
    on login_events(device_hash);
create index if not exists login_events_created_idx
    on login_events(created_at desc);

alter table login_events enable row level security;

-- Utente: può inserire solo eventi per se stesso
drop policy if exists login_events_insert_own on login_events;
create policy login_events_insert_own
    on login_events for insert to authenticated
    with check (user_id = auth.uid());

-- Utente: vede i suoi eventi; admin: vede tutto
drop policy if exists login_events_select on login_events;
create policy login_events_select
    on login_events for select to authenticated
    using (user_id = auth.uid() or is_admin());

-- Admin: può cancellare eventi (pulizia/retention manuale se serve)
drop policy if exists login_events_admin_delete on login_events;
create policy login_events_admin_delete
    on login_events for delete to authenticated
    using (is_admin());

grant select, insert on login_events to authenticated;
grant delete on login_events to authenticated;
