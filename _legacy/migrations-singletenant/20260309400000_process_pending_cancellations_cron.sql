-- ─── RPC: process_pending_cancellations ──────────────────────────────────────
-- Porting server-side di BookingStorage.processPendingCancellations() (data.js:664)
--
-- Logica: per ogni booking con status='cancellation_requested',
-- se mancano meno di 2 ore all'inizio della lezione → torna 'confirmed'
-- (il cliente non può più annullare in extremis senza che arrivi un sostituto).
--
-- Schedulata via pg_cron ogni 15 minuti (vedi sotto).
-- SECURITY DEFINER: bypassa RLS per poter fare UPDATE come superuser.

create or replace function process_pending_cancellations()
returns integer language plpgsql security definer
set search_path = public as $$
declare
    v_count        integer := 0;
    v_lesson_start timestamptz;
    v_booking      record;
begin
    for v_booking in
        select id, date, time
        from   bookings
        where  status = 'cancellation_requested'
          -- Considera solo le prossime 48h: non toccare robe storiche
          and   date >= (now() - interval '24 hours')::date
          and   date <= (now() + interval '48 hours')::date
    loop
        -- Estrai l'orario di inizio dalla stringa "HH:MM - HH:MM"
        v_lesson_start := (
            v_booking.date::text || ' ' ||
            trim(split_part(v_booking.time, ' - ', 1)) ||
            ':00'
        )::timestamptz;

        -- Se mancano ≤ 2 ore all'inizio → nega l'annullamento, riporta a confirmed
        if v_lesson_start - now() <= interval '2 hours' then
            update bookings set status = 'confirmed' where id = v_booking.id;
            v_count := v_count + 1;
        end if;
    end loop;

    return v_count; -- numero di booking ripristinati
end;
$$;

-- Consenti la chiamata solo a utenti autenticati (e al cron job interno)
revoke all on function process_pending_cancellations() from public;
grant execute on function process_pending_cancellations() to authenticated;
grant execute on function process_pending_cancellations() to service_role;

-- ─── PG_CRON ─────────────────────────────────────────────────────────────────
-- PREREQUISITO: abilitare pg_cron PRIMA di eseguire questo blocco.
--   Dashboard Supabase → Database → Extensions → cerca "pg_cron" → Enable
--
-- Poi esegui nel SQL Editor (SEPARATAMENTE, dopo aver abilitato l'estensione):
--
--   select cron.schedule(
--       'process-pending-cancellations',   -- nome job (univoco)
--       '*/15 * * * *',                    -- ogni 15 minuti
--       $$select process_pending_cancellations()$$
--   );
--
-- Per verificare che il job sia registrato:
--   select * from cron.job;
--
-- Per rimuovere il job (se necessario):
--   select cron.unschedule('process-pending-cancellations');
