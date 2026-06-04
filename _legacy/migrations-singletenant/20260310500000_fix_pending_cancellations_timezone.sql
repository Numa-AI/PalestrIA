-- ─── FIX TIMEZONE: process_pending_cancellations ────────────────────────────
-- Il cast precedente ('YYYY-MM-DD HH:MM:00')::timestamptz interpretava l'ora
-- come UTC (timezone di sessione Supabase), invece di Europe/Rome.
-- Una lezione alle 10:40 ora italiana veniva trattata come 10:40 UTC (+1/+2h di errore).
-- Fix: aggiungere ' Europe/Rome' alla stringa prima del cast.

create or replace function process_pending_cancellations()
returns integer language plpgsql security definer
set search_path = public as $$
declare
    v_count        integer := 0;
    v_lesson_start timestamptz;
    v_booking      record;
begin
    if not is_admin() and current_setting('role', true) <> 'service_role' then
        raise exception 'Accesso negato';
    end if;

    for v_booking in
        select id, date, time
        from   bookings
        where  status = 'cancellation_requested'
          and  date >= (now() at time zone 'Europe/Rome')::date - 1
          and  date <= (now() at time zone 'Europe/Rome')::date + 2
    loop
        -- Estrai l'orario di inizio dalla stringa "HH:MM - HH:MM"
        -- Aggiunge il fuso Europe/Rome per il cast corretto
        v_lesson_start := (
            v_booking.date::text || ' ' ||
            trim(split_part(v_booking.time, ' - ', 1)) ||
            ':00 Europe/Rome'
        )::timestamptz;

        -- Se mancano ≤ 2 ore all'inizio → nega l'annullamento, riporta a confirmed
        if v_lesson_start - now() <= interval '2 hours' then
            update bookings set status = 'confirmed' where id = v_booking.id;
            v_count := v_count + 1;
        end if;
    end loop;

    return v_count;
end;
$$;

-- Mantieni gli stessi grant della versione precedente
revoke all on function process_pending_cancellations() from public;
grant execute on function process_pending_cancellations() to authenticated;
grant execute on function process_pending_cancellations() to service_role;
