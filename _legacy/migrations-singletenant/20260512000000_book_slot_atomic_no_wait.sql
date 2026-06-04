-- Evita attese indefinite durante la prenotazione di uno slot.

create index if not exists bookings_active_slot_idx
    on bookings (date, time, slot_type)
    where status in ('confirmed', 'cancellation_requested');

create or replace function book_slot_atomic(
    p_local_id      text,
    p_user_id       uuid,
    p_date          text,
    p_time          text,
    p_slot_type     text,
    p_max_capacity  integer,
    p_name          text,
    p_email         text,
    p_whatsapp      text,
    p_notes         text,
    p_created_at    timestamptz,
    p_date_display  text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public as $$
declare
    v_count      integer;
    v_id         uuid;
    v_email      text := lower(trim(coalesce(p_email, '')));
    v_start_time time;
    v_lesson_dt  timestamptz;
begin
    if v_email <> '' and
       v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' then
        return jsonb_build_object('success', false, 'error', 'invalid_email');
    end if;

    if p_date::date < current_date and not is_admin() then
        return jsonb_build_object('success', false, 'error', 'past_date');
    end if;

    if p_name is null or trim(p_name) = '' then
        return jsonb_build_object('success', false, 'error', 'missing_name');
    end if;

    if p_max_capacity <= 0 then
        return jsonb_build_object('success', false, 'error', 'invalid_capacity');
    end if;

    if not is_admin() then
        v_start_time := split_part(p_time, ' - ', 1)::time;
        v_lesson_dt  := (p_date::date + v_start_time) at time zone 'Europe/Rome';

        if now() > v_lesson_dt + interval '30 minutes' then
            return jsonb_build_object('success', false, 'error', 'too_late');
        end if;
    end if;

    if not pg_try_advisory_xact_lock(hashtext(p_date || '|' || p_time || '|' || p_slot_type)) then
        return jsonb_build_object('success', false, 'error', 'slot_busy');
    end if;

    select count(*) into v_count
    from bookings
    where date      = p_date::date
      and time      = p_time
      and slot_type = p_slot_type
      and status in ('confirmed', 'cancellation_requested');

    if v_count >= p_max_capacity then
        return jsonb_build_object('success', false, 'error', 'slot_full');
    end if;

    insert into bookings (
        local_id, user_id, date, time, slot_type,
        name, email, whatsapp, notes, status, created_at, date_display,
        created_by
    ) values (
        p_local_id, p_user_id, p_date::date, p_time, p_slot_type,
        trim(p_name), nullif(v_email, ''), nullif(trim(coalesce(p_whatsapp, '')), ''), p_notes,
        'confirmed', p_created_at, p_date_display,
        auth.uid()
    )
    returning id into v_id;

    return jsonb_build_object('success', true, 'booking_id', v_id::text);
exception
    when unique_violation then
        return jsonb_build_object('success', false, 'error', 'duplicate_booking');
end;
$$;

revoke all on function book_slot_atomic from public;
grant execute on function book_slot_atomic to authenticated;
