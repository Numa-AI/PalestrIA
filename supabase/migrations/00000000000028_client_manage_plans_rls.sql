-- ─────────────────────────────────────────────────────────────────────────────
-- 00000000000028 — Schede gestibili dai clienti (opt-in per-org)
--
-- Contesto: le schede/esercizi (workout_plans, workout_exercises) sono scrivibili
-- SOLO dagli admin (policy *_admin della baseline). L'app cliente (PWA + Flutter)
-- espone però i pulsanti crea/rinomina/elimina scheda ed esercizi: senza questa
-- migration quei tentativi falliscono (INSERT → 42501) o vanno a vuoto (UPDATE/
-- DELETE → 0 righe), mostrando falsi "fatto".
--
-- Scelta di prodotto (configurabile dal trainer): un flag org
-- `features.client_manage_plans` (org_settings, default assente = FALSE) decide
-- se i clienti possono gestire le PROPRIE schede. Quando è TRUE, questa policy
-- concede al cliente la scrittura sulle proprie righe; quando è FALSE resta
-- tutto admin-only (comportamento storico). I log serie/peso (workout_logs)
-- restano sempre consentiti al proprietario (policy own_write già in baseline).
--
-- Lato app: il toggle sta in Impostazioni → Funzionalità; la UI cliente mostra
-- i controlli di modifica struttura solo se il flag è ON (o se admin). Nel
-- Flutter è già gestito (workout_screen `_canManage`); nel WEB va replicato il
-- gate UI (allenamento.html) — vedi todo.
-- ─────────────────────────────────────────────────────────────────────────────

-- Helper: il flag org è attivo? (jsonb boolean in org_settings). STABLE + definer
-- così è chiamabile dalle policy senza esporre org_settings.
create or replace function client_can_manage_plans(p_org_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
    select coalesce(
        (select value = 'true'::jsonb
           from org_settings
          where org_id = p_org_id
            and key = 'features.client_manage_plans'),
        false)
$$;
revoke all on function client_can_manage_plans(uuid) from public;
grant execute on function client_can_manage_plans(uuid) to authenticated;

-- workout_plans: il cliente gestisce le PROPRIE schede quando il flag è ON.
-- (Permissiva: si somma in OR alle policy admin/select esistenti — nessuna
--  regressione quando il flag è OFF.)
drop policy if exists workout_plans_own_manage on workout_plans;
create policy workout_plans_own_manage on workout_plans
    for all to authenticated
    using (
        user_id = auth.uid()
        and org_id = current_org_id()
        and client_can_manage_plans(org_id)
    )
    with check (
        user_id = auth.uid()
        and org_id = current_org_id()
        and client_can_manage_plans(org_id)
    );

-- workout_exercises: nessun user_id sulla riga → l'ownership passa dal plan.
drop policy if exists workout_exercises_own_manage on workout_exercises;
create policy workout_exercises_own_manage on workout_exercises
    for all to authenticated
    using (
        org_id = current_org_id()
        and client_can_manage_plans(org_id)
        and exists (
            select 1 from workout_plans p
             where p.id = workout_exercises.plan_id
               and p.user_id = auth.uid()
        )
    )
    with check (
        org_id = current_org_id()
        and client_can_manage_plans(org_id)
        and exists (
            select 1 from workout_plans p
             where p.id = workout_exercises.plan_id
               and p.user_id = auth.uid()
        )
    );
