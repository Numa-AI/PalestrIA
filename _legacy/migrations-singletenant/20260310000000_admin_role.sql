-- ─── RUOLO ADMIN ─────────────────────────────────────────────────────────────
-- Eseguire nel SQL Editor di Supabase.
-- Imposta il custom claim "role: admin" per PalestrIA e protegge tutte le RPC admin.

-- ── Step 1: imposta app_metadata.role = 'admin' per l'admin ────────────────────
update auth.users
set raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}'::jsonb
where id in (
    'ac72d54b-dea4-4159-9872-2bcb1662c486',  -- demo@palestria.app
    'cf5f39f3-1581-40be-80e9-15b56acee337'   -- andrea.pompili1997@gmail.com
);

-- ── Step 2: funzione helper is_admin() ────────────────────────────────────────
create or replace function is_admin()
returns boolean language sql stable security definer as $$
    select coalesce(
        (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin',
        false
    )
$$;

-- ── Step 3: proteggi le RPC admin ─────────────────────────────────────────────

-- admin_delete_booking
create or replace function admin_delete_booking(p_booking_id uuid)
returns void language plpgsql security definer
set search_path = public as $$
begin
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;
    delete from bookings where id = p_booking_id;
end;
$$;
revoke all on function admin_delete_booking(uuid) from public;
grant execute on function admin_delete_booking(uuid) to authenticated;

-- admin_update_booking
create or replace function admin_update_booking(
    p_booking_id                uuid,
    p_status                    text,
    p_paid                      boolean                   default false,
    p_payment_method            text                      default null,
    p_paid_at                   timestamp with time zone  default null,
    p_credit_applied            numeric                   default 0,
    p_cancellation_requested_at timestamp with time zone  default null,
    p_cancelled_at              timestamp with time zone  default null,
    p_cancelled_payment_method  text                      default null,
    p_cancelled_paid_at         timestamp with time zone  default null,
    p_cancelled_with_bonus      boolean                   default false,
    p_cancelled_with_penalty    boolean                   default false
)
returns void language plpgsql security definer
set search_path = public as $$
begin
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;
    update bookings set
        status                    = p_status,
        paid                      = p_paid,
        payment_method            = p_payment_method,
        paid_at                   = p_paid_at,
        credit_applied            = p_credit_applied,
        cancellation_requested_at = p_cancellation_requested_at,
        cancelled_at              = p_cancelled_at,
        cancelled_payment_method  = p_cancelled_payment_method,
        cancelled_paid_at         = p_cancelled_paid_at,
        cancelled_with_bonus      = p_cancelled_with_bonus,
        cancelled_with_penalty    = p_cancelled_with_penalty
    where id = p_booking_id;
end;
$$;
revoke all on function admin_update_booking(uuid,text,boolean,text,timestamptz,numeric,timestamptz,timestamptz,text,timestamptz,boolean,boolean) from public;
grant execute on function admin_update_booking(uuid,text,boolean,text,timestamptz,numeric,timestamptz,timestamptz,text,timestamptz,boolean,boolean) to authenticated;

-- process_pending_cancellations
-- ⚠️ Il cron pg_cron gira come postgres (uid = null) → non bloccare se uid è null
create or replace function process_pending_cancellations()
returns integer language plpgsql security definer
set search_path = public as $$
declare
    v_count        integer := 0;
    v_lesson_start timestamptz;
    v_booking      record;
begin
    if auth.uid() is not null and not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

    for v_booking in
        select id, date, time
        from   bookings
        where  status = 'cancellation_requested'
          and  date >= (now() - interval '24 hours')::date
          and  date <= (now() + interval '48 hours')::date
    loop
        v_lesson_start := (
            v_booking.date::text || ' ' ||
            trim(split_part(v_booking.time, ' - ', 1)) ||
            ':00'
        )::timestamptz;

        if v_lesson_start - now() <= interval '2 hours' then
            update bookings set status = 'confirmed' where id = v_booking.id;
            v_count := v_count + 1;
        end if;
    end loop;

    return v_count;
end;
$$;
revoke all on function process_pending_cancellations() from public;
grant execute on function process_pending_cancellations() to authenticated;
grant execute on function process_pending_cancellations() to service_role;

-- apply_credits_to_bookings (non ancora usata dal frontend, preparata per futuro)
create or replace function apply_credits_to_bookings(p_user_id uuid)
returns json language plpgsql security definer as $$
declare
    v_credit_id     uuid;
    v_balance       numeric(10,2);
    v_booking       record;
    v_price         numeric(10,2);
    v_remaining     numeric(10,2);
    v_total_applied numeric(10,2) := 0;
    v_count         integer       := 0;
    v_now           timestamptz   := now();
begin
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

    select id, balance into v_credit_id, v_balance
    from   credits where user_id = p_user_id for update;

    if v_credit_id is null or v_balance <= 0 then
        return json_build_object('applied', 0, 'count', 0);
    end if;

    for v_booking in
        select * from bookings
        where  user_id = p_user_id and paid = false and status = 'confirmed'
        order  by date asc, time asc for update
    loop
        v_price := case v_booking.slot_type
            when 'personal-training' then 5
            when 'small-group'       then 10
            when 'group-class'       then 50
            else 0
        end;
        v_remaining := v_price - coalesce(v_booking.credit_applied, 0);

        if v_balance >= v_remaining then
            update bookings set paid = true, payment_method = 'credito',
                paid_at = v_now, credit_applied = 0 where id = v_booking.id;
            v_balance       := v_balance - v_remaining;
            v_total_applied := v_total_applied + v_remaining;
            v_count         := v_count + 1;
        elsif v_balance > 0 and coalesce(v_booking.credit_applied, 0) = 0 then
            update bookings set credit_applied = v_balance where id = v_booking.id;
            v_total_applied := v_total_applied + v_balance;
            v_balance       := 0;
        end if;

        exit when v_balance <= 0;
    end loop;

    if v_total_applied > 0 then
        update credits set balance = v_balance where id = v_credit_id;
        insert into credit_history (credit_id, amount, note) values (
            v_credit_id, -v_total_applied,
            'Auto-pagamento ' || v_count || ' lezione' || case when v_count > 1 then 'i' else '' end || ' con credito'
        );
    end if;

    return json_build_object('applied', v_total_applied, 'count', v_count);
end;
$$;

-- get_unpaid_past_debt (non ancora usata dal frontend)
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
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

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

-- get_or_reset_bonus (non ancora usata dal frontend)
create or replace function get_or_reset_bonus(p_user_id uuid)
returns integer language plpgsql security definer as $$
declare
    v_this_month text := to_char(now(), 'YYYY-MM');
    v_record     record;
begin
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

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
