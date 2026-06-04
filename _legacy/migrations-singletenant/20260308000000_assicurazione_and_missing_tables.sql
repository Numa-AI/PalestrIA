-- ─── PROFILES: aggiungi campi assicurazione ──────────────────────────────────
alter table profiles
    add column if not exists insurance_expiry  date,
    add column if not exists insurance_history jsonb not null default '[]';

-- ─── SETTINGS ────────────────────────────────────────────────────────────────
create table if not exists settings (
    key        text primary key,
    value      text,
    updated_at timestamptz not null default now()
);

alter table settings enable row level security;

drop policy if exists "settings_select_public" on settings;
create policy "settings_select_public"
    on settings for select to anon, authenticated using (true);

insert into settings (key, value) values
    ('debt_threshold',        '0'),
    ('cancellation_mode',     'new-person'),
    ('cert_block_expired',    'false'),
    ('cert_block_not_set',    'false'),
    ('assic_block_expired',   'false'),
    ('assic_block_not_set',   'false'),
    ('cert_scadenza_editable','true')
on conflict (key) do nothing;

-- ─── MANUAL DEBTS ────────────────────────────────────────────────────────────
create table if not exists manual_debts (
    id         uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    user_id    uuid references profiles(id) on delete set null,
    name       text not null,
    whatsapp   text,
    email      text not null,
    balance    numeric(10,2) not null default 0,
    history    jsonb not null default '[]'
);

alter table manual_debts enable row level security;

drop policy if exists "manual_debts_select_own" on manual_debts;
create policy "manual_debts_select_own"
    on manual_debts for select to authenticated using (user_id = auth.uid());

create index if not exists manual_debts_user_id_idx on manual_debts (user_id);
create index if not exists manual_debts_email_idx   on manual_debts (email);

-- ─── BONUSES ─────────────────────────────────────────────────────────────────
create table if not exists bonuses (
    id               uuid primary key default gen_random_uuid(),
    created_at       timestamptz not null default now(),
    user_id          uuid references profiles(id) on delete cascade,
    name             text not null,
    whatsapp         text,
    email            text not null unique,
    bonus            integer not null default 1 check (bonus in (0, 1)),
    last_reset_month text,
    updated_at       timestamptz not null default now()
);

alter table bonuses enable row level security;

drop policy if exists "bonuses_select_own" on bonuses;
create policy "bonuses_select_own"
    on bonuses for select to authenticated using (user_id = auth.uid());

create index if not exists bonuses_user_id_idx on bonuses (user_id);
create index if not exists bonuses_email_idx   on bonuses (email);

-- ─── PUSH SUBSCRIPTIONS ──────────────────────────────────────────────────────
create table if not exists push_subscriptions (
    id         uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    user_id    uuid references profiles(id) on delete cascade,
    endpoint   text not null unique,
    p256dh     text not null,
    auth       text not null
);

alter table push_subscriptions enable row level security;

drop policy if exists "push_subscriptions_insert_own" on push_subscriptions;
create policy "push_subscriptions_insert_own"
    on push_subscriptions for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "push_subscriptions_select_own" on push_subscriptions;
create policy "push_subscriptions_select_own"
    on push_subscriptions for select to authenticated using (user_id = auth.uid());

drop policy if exists "push_subscriptions_delete_own" on push_subscriptions;
create policy "push_subscriptions_delete_own"
    on push_subscriptions for delete to authenticated using (user_id = auth.uid());

-- ─── BOOKINGS: colonne mancanti ──────────────────────────────────────────────
alter table bookings
    add column if not exists cancelled_payment_method text,
    add column if not exists cancelled_paid_at        timestamptz,
    add column if not exists cancelled_with_bonus     boolean not null default false,
    add column if not exists cancelled_with_penalty   boolean not null default false,
    add column if not exists date_display             text;

-- ─── RPC: get_or_reset_bonus ─────────────────────────────────────────────────
create or replace function get_or_reset_bonus(p_user_id uuid)
returns integer language plpgsql security definer as $$
declare
    v_this_month text := to_char(now(), 'YYYY-MM');
    v_record     record;
begin
    select * into v_record from bonuses where user_id = p_user_id;
    if not found then return 1; end if;
    if v_record.last_reset_month is distinct from v_this_month and v_record.bonus = 0 then
        update bonuses set bonus = 1, last_reset_month = v_this_month, updated_at = now()
        where user_id = p_user_id;
        return 1;
    end if;
    return v_record.bonus;
end;
$$;

-- ─── RPC: get_unpaid_past_debt ────────────────────────────────────────────────
create or replace function get_unpaid_past_debt(p_user_id uuid)
returns numeric language plpgsql security definer as $$
declare
    v_booking_debt   numeric(10,2) := 0;
    v_credit_balance numeric(10,2) := 0;
    v_manual_debt    numeric(10,2) := 0;
    v_now            timestamptz   := now();
    v_price          numeric(10,2);
    v_end_dt         timestamptz;
    v_booking        record;
begin
    for v_booking in
        select slot_type, date, time, credit_applied from bookings
        where  user_id = p_user_id and paid = false
          and  status not in ('cancelled', 'cancellation_requested')
    loop
        v_price := case v_booking.slot_type
            when 'personal-training' then 5
            when 'small-group'       then 10
            when 'group-class'       then 50
            else 0
        end;
        v_end_dt := (v_booking.date::text || ' ' ||
                     split_part(v_booking.time, ' - ', 2) || ':00')::timestamptz;
        if v_now >= v_end_dt then
            v_booking_debt := v_booking_debt + v_price - coalesce(v_booking.credit_applied, 0);
        end if;
    end loop;

    select coalesce(balance, 0) into v_credit_balance from credits where user_id = p_user_id;
    select coalesce(balance, 0) into v_manual_debt    from manual_debts where user_id = p_user_id;

    return greatest(0, v_booking_debt + v_manual_debt - v_credit_balance);
end;
$$;
