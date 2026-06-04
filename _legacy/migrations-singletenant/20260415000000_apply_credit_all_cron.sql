-- ─── RPC apply_credit_to_past_bookings_all + pg_cron ──────────────────────────
-- Wrapper che processa in un colpo solo tutti i clienti con credito positivo,
-- delegando alla RPC per-email esistente `apply_credit_to_past_bookings`.
--
-- Motivazione: oggi i client (admin.html, admin-calendar.js) fanno fan-out
-- chiamando la RPC per-email per ogni cliente ad ogni page load →
-- ~500+ chiamate/ora osservate. Spostando il reconcile "a tempo" su pg_cron
-- ogni minuto, tagliamo le chiamate a ~60/ora senza perdere reattività:
-- le chiamate user/event-driven (index.html, prenotazioni.html,
-- admin-payments.js dopo aggiunta credito) restano istantanee.
--
-- La funzione NON modifica `apply_credit_to_past_bookings` (invariata).
-- Pre-filter: solo clienti con credito E almeno un booking passato non pagato,
-- per evitare FOR UPDATE lock e funzione calls inutili.

create or replace function apply_credit_to_past_bookings_all()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_email               text;
    v_clients_processed   integer := 0;
    v_total_bookings_paid integer := 0;
    v_total_applied       numeric(10,2) := 0;
    v_now_rome            timestamp := (now() at time zone 'Europe/Rome');
    v_today               date      := v_now_rome::date;
    v_current_time        time      := v_now_rome::time;
    v_result              jsonb;
begin
    -- Guard: pg_cron gira con auth.uid() null (ruolo postgres) → lasciare passare.
    -- Utenti autenticati non admin → bloccati. Stesso pattern di
    -- process_pending_cancellations (migrations/20260310000000_admin_role.sql).
    if auth.uid() is not null and not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

    for v_email in
        select distinct c.email
        from   credits c
        where  c.email is not null
          and  c.balance > 0
          and  exists (
                  select 1
                  from   bookings b
                  where  lower(b.email) = lower(c.email)
                    and  b.paid   = false
                    and  b.status = 'confirmed'
                    and  (
                            b.date <  v_today
                         or (b.date = v_today
                             and split_part(b.time, ' - ', 1)::time <= v_current_time)
                    )
              )
    loop
        v_result := apply_credit_to_past_bookings(v_email);
        v_clients_processed   := v_clients_processed + 1;
        v_total_bookings_paid := v_total_bookings_paid + coalesce((v_result->>'bookings_paid')::int, 0);
        v_total_applied       := v_total_applied       + coalesce((v_result->>'total_applied')::numeric, 0);
    end loop;

    return jsonb_build_object(
        'success',            true,
        'clients_processed',  v_clients_processed,
        'bookings_paid',      v_total_bookings_paid,
        'total_applied',      v_total_applied
    );
end;
$$;

revoke all on function apply_credit_to_past_bookings_all() from public;
grant execute on function apply_credit_to_past_bookings_all() to service_role;
grant execute on function apply_credit_to_past_bookings_all() to authenticated;
-- NON concedere a anon. L'accesso da `authenticated` è filtrato dalla guard
-- interna `is_admin()`, che blocca utenti non admin ma lascia passare pg_cron
-- (auth.uid() is null). admin.html usa questa funzione per il reconcile on-load
-- come safety net: 1 sola chiamata, non più N.

-- ─── PG_CRON ─────────────────────────────────────────────────────────────────
-- PREREQUISITO: pg_cron deve essere abilitato.
--   Dashboard Supabase → Database → Extensions → cerca "pg_cron" → Enable
--   (risulta già installato tra le Integrations).
--
-- Esegui MANUALMENTE nel SQL Editor dopo aver applicato questa migration:
--
--   select cron.schedule(
--       'apply-credit-to-past-bookings-all',  -- nome job (univoco)
--       '* * * * *',                          -- ogni minuto
--       $$select apply_credit_to_past_bookings_all()$$
--   );
--
-- Verificare che il job sia registrato:
--   select jobid, jobname, schedule, active from cron.job;
--
-- Storico ultime esecuzioni (per verificare che gira senza errori):
--   select start_time, status, return_message
--   from   cron.job_run_details
--   where  jobname = 'apply-credit-to-past-bookings-all'
--   order  by start_time desc
--   limit  10;
--
-- Rimuovere il job (se necessario):
--   select cron.unschedule('apply-credit-to-past-bookings-all');
