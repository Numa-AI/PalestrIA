-- ─────────────────────────────────────────────────────────────────────────────
-- Hardening grant: chiude il lint Supabase 0028 (Public Can Execute SECURITY DEFINER
-- Function) e 0011 (Function Search Path Mutable) emersi dal Security Advisor sul DB LIVE.
--
-- PROBLEMA: sul DB live moltissime funzioni `SECURITY DEFINER` risultavano eseguibili da
-- `anon` via REST. Causa: il grant di DEFAULT a `PUBLIC` (che include `anon`) — alcuni file
-- non lo revocavano affatto (helper: current_org_id, resolve_slot_config, …), e su altre il
-- DB live era driftato dai file (le admin_* hanno `revoke … from public` nei file ma sul live
-- il permesso era tornato). Le admin_* erano comunque protette dalla `is_org_admin()` interna
-- (un anon becca "unauthorized") → difesa in profondità, non breach attivo; ma va chiuso.
--
-- TRAPPOLA Postgres: `REVOKE … FROM anon` è NO-OP se il permesso è concesso a `PUBLIC`
-- (default alla creazione della funzione) → serve `REVOKE … FROM PUBLIC` e poi ri-GRANT.
--
-- STRATEGIA (idempotente, rieseguibile, vale anche per i deploy greenfield perché gira dopo
-- la baseline): per OGNI funzione `SECURITY DEFINER` in `public`
--   1) revoca `EXECUTE` da PUBLIC e anon (toglie l'accesso anonimo di default);
--   2) ri-concede `authenticated` (STATUS QUO: chi era authenticated lo resta — le funzioni
--      admin si proteggono da sole con is_org_admin(); gli helper RLS DEVONO restare eseguibili
--      da authenticated perché le policy RLS li chiamano come utente corrente), TRANNE le
--      funzioni solo-service_role (deny-list);
--   3) ri-concede `anon` SOLO all'allowlist del flusso pubblico (prenotazione/branding + kiosk).
-- NB1: i grant a `service_role` non vengono toccati (si revoca solo PUBLIC/anon).
-- NB2: le trigger function (handle_new_user, trg_set_updated_at, _guard_org_stripe_cols) sono
--   trattate come le altre: tolto anon (chiude il lint 0028); restano firing comunque (il
--   trigger non richiede EXECUTE) e una chiamata diretta via REST fallisce (manca il record).
-- ─────────────────────────────────────────────────────────────────────────────

do $$
declare
  r record;
  -- Allowlist: funzioni che DEVONO restare eseguibili da `anon`.
  --  - Flusso prenotazione/branding pubblico (client non loggato su index/prenotazioni)
  --  - Kiosk tablet (client Supabase anonimo isolato in tablet.html)
  allow_anon text[] := array[
    'book_slot','get_availability_range','get_slot_availability','get_slot_attendees',
    'is_whatsapp_taken','get_public_org_settings',
    'kiosk_load_workout','kiosk_load_progress','kiosk_exercise_catalog','kiosk_save_logs',
    'kiosk_delete_logs','kiosk_update_exercise','kiosk_add_exercises','kiosk_reorder_exercises',
    'kiosk_delete_exercise','kiosk_delete_superset','kiosk_rename_plan'
  ];
  -- Funzioni che NON devono avere `authenticated` (solo service_role: cron/edge).
  deny_authenticated text[] := array['process_pending_cancellations'];
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef = true
  loop
    -- 1) togli il default PUBLIC (che concede execute ad anon) + anon esplicito
    execute format('revoke execute on function %s from public', r.sig);
    execute format('revoke execute on function %s from anon', r.sig);

    -- 2) authenticated mantiene l'accesso (status quo), tranne le solo-service_role
    if not (r.proname = any(deny_authenticated)) then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;

    -- 3) ri-concedi anon solo all'allowlist del flusso pubblico
    if r.proname = any(allow_anon) then
      execute format('grant execute on function %s to anon', r.sig);
    end if;
  end loop;
end $$;

-- Lint 0011 — Function Search Path Mutable: fissa il search_path sul trigger updated_at.
do $$
begin
  if to_regprocedure('public.trg_set_updated_at()') is not null then
    alter function public.trg_set_updated_at() set search_path = public;
  end if;
end $$;

-- Lint 0008 (INFO) — stripe_oauth_states ha RLS ON ma nessuna policy = deny-all (corretto:
-- la tabella è usata SOLO dalle edge function via service_role, che bypassa RLS). Rendiamo
-- esplicito l'intento con una policy deny-all (silenzia l'advisor senza cambiare l'accesso).
do $$
begin
  if to_regclass('public.stripe_oauth_states') is not null
     and not exists (
       select 1 from pg_policies
       where schemaname = 'public' and tablename = 'stripe_oauth_states'
         and policyname = 'stripe_oauth_states_no_client_access'
     ) then
    create policy stripe_oauth_states_no_client_access
      on public.stripe_oauth_states for all
      to anon, authenticated
      using (false) with check (false);
  end if;
end $$;
