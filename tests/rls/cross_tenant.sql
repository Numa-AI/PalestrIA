-- ══════════════════════════════════════════════════════════════════════════════
-- tests/rls/cross_tenant.sql — Test di isolamento multi-tenant (RLS + org_id)
--
-- COSA DIMOSTRA
--   La piattaforma è multi-tenant pooled: ogni studio è una `organizations` e i
--   dati sono isolati a livello DB da Row Level Security su `org_id`. Questo script
--   prova che un MEMBRO della org A non può MAI leggere/aggiornare/cancellare/
--   inserire dati nella org B (e viceversa), e che le RPC pubbliche org-scoped non
--   mescolano dati tra org diverse rispetto allo slug richiesto.
--
-- COME SI ESEGUE (vedi .github/workflows/ci.yml, job db-baseline)
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f tests/rls/cross_tenant.sql
--   contro il DB creato da `supabase db reset` (baseline + seed, eventualmente con
--   le migration operative 00000000000001+ già applicate).
--   Una qualsiasi `raise exception` interrompe lo script con exit code != 0 e
--   fa fallire la CI. Se tutto passa, l'ultima riga stampa il notice di successo.
--
-- PERCHÉ FUNZIONA (gotcha noti)
--   • RLS NON si applica al superuser/owner (postgres). Per testare DAVVERO le
--     policy bisogna `SET LOCAL ROLE authenticated` dentro la transazione.
--   • I claim si simulano con set_config('request.jwt.claims', …, true) — true =
--     transaction-local — PRIMA del cambio ruolo (dopo si perde il privilegio di
--     scrivere quella GUC, ma resta leggibile da current_org_id()).
--   • create_organization è SECURITY DEFINER → per il SETUP gira come definer e
--     bypassa RLS: basta che request.jwt.claims->>'sub' sia l'owner giusto.
--   • Gli id delle org NON viaggiano in una temp table: una temp table creata da
--     `postgres` NON è accessibile dal ruolo `authenticated` (manca il GRANT su
--     pg_temp → `permission denied for table …`, SQLSTATE 42501). Usiamo invece
--     GUC custom di SESSIONE (`palestria.org_a`/`palestria.org_b`), che sono
--     INDIPENDENTI dal ruolo: leggibili con current_setting() anche sotto
--     `authenticated`, senza alcun ACL di tabella, e sopravvivono ai begin/commit.
--   • ANTI-FALSE-PASS: prima delle asserzioni di invisibilità inseriamo dati REALI
--     in ENTRAMBE le org, e ogni direzione verifica sia di NON vedere l'altra org
--     sia di vedere la propria. Per le RPC pubbliche entrambe le org hanno una
--     booking sullo stesso slot/data: verifichiamo il conteggio ESATTO per slug
--     (1, non 2) così un mancato filtro per org verrebbe rilevato. La FASE 6
--     prova anche che una scrittura LEGITTIMA nella propria org RIESCE (esclude
--     che la WITH CHECK stia bloccando tutto indiscriminatamente).
--
-- Niente dipendenze esterne (no pgTAP): solo SQL/plpgsql puro.
-- ══════════════════════════════════════════════════════════════════════════════

\set ON_ERROR_STOP on

-- UID e slug FISSI e deterministici (riconoscibili, riutilizzabili tra i run).
-- I valori sono cablati anche nelle stringhe JSON dei claim più sotto: se li
-- cambi qui, aggiornali anche nei set_config('request.jwt.claims', …).
--   uid_a = aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa   slug A = rls-test-a
--   uid_b = bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb   slug B = rls-test-b
-- Slot condiviso usato per le RPC di disponibilità (data fissa nel futuro: niente
-- dipendenze dall'ora di esecuzione/DST). Il weekday del template lo calcoliamo in
-- SQL così combacia con qualunque data scelta.
--   data = 2099-01-15   ora = '09:00 - 10:00'   slot_type = 'group-class'

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 0 — PULIZIA IDEMPOTENTE (come postgres). Rimuove eventuali residui di run
-- precedenti per gli uid/slug fissi, così lo script può rigirare senza errori
-- (slug_taken / chiavi duplicate). Le org cancellate fanno cascade su members,
-- profiles, payments, packages, bookings, subscriptions, settings, ecc.
-- ──────────────────────────────────────────────────────────────────────────────
delete from organizations where slug in ('rls-test-a', 'rls-test-b');
delete from auth.users
 where id in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
              'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 1 — UTENTI auth.users (come postgres, RLS bypassata)
-- Inserimento minimale-ma-valido per GoTrue locale. raw_user_meta_data con
-- signup_type='trainer' → il trigger handle_new_user fa "return new" SENZA creare
-- profili automatici: l'org la crea poi create_organization. Tutte le colonne
-- *_token / *_change note di GoTrue a '' (stringa vuota): diverse versioni le
-- dichiarano NOT NULL DEFAULT '', e popolarle esplicitamente rende l'insert
-- robusto alle differenze di versione. crypt() richiede pgcrypto (presente in
-- Supabase). email_confirmed_at = now() = utente confermato.
-- ──────────────────────────────────────────────────────────────────────────────
insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current, email_change,
    phone_change, phone_change_token, reauthentication_token
) values (
    '00000000-0000-0000-0000-000000000000',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'authenticated', 'authenticated', 'rls-a@test.dev',
    crypt('password123', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"signup_type":"trainer"}'::jsonb,
    false, '', '', '', '', '', '', '', ''
) on conflict (id) do nothing;

insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token,
    email_change_token_new, email_change_token_current, email_change,
    phone_change, phone_change_token, reauthentication_token
) values (
    '00000000-0000-0000-0000-000000000000',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'authenticated', 'authenticated', 'rls-b@test.dev',
    crypt('password123', gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"signup_type":"trainer"}'::jsonb,
    false, '', '', '', '', '', '', '', ''
) on conflict (id) do nothing;

-- Sanity-check: gli utenti DEVONO esistere, altrimenti create_organization
-- fallirebbe con 'not_authenticated' (auth.uid() = sub del claim → riga in users).
do $$
begin
    if not exists (select 1 from auth.users where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
       or not exists (select 1 from auth.users where id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') then
        raise exception 'SETUP: insert in auth.users non riuscito (utenti di test mancanti)';
    end if;
end $$;

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 2 — ORG A e ORG B via create_organization (SECURITY DEFINER → bypassa RLS).
-- Impersoniamo l'owner SOLO impostando request.jwt.claims->>'sub' (auth.uid()).
-- NON serve SET ROLE qui (gira come postgres/definer): il SETUP non esercita RLS,
-- l'isolamento è provato in FASE 4/5/6. Catturiamo l'uuid restituito e lo stashiamo
-- in GUC di SESSIONE (set_config(...,false)) per trasportarlo alle fasi seguenti
-- (sopravvive ai begin/commit ed è leggibile sotto qualunque ruolo).
-- create_organization crea per ciascuna org: organizations(status='trialing'),
-- org_members(owner), billing_settings, subscriptions(plan 'starter', trial 30gg),
-- 3 slot_types (incl. 'group-class' capacity 12), 6 org_settings.
-- ──────────────────────────────────────────────────────────────────────────────
do $$
declare v_org uuid;
begin
    perform set_config(
        'request.jwt.claims',
        '{"sub":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","role":"authenticated","app_metadata":{}}',
        true);
    v_org := create_organization('RLS Test Studio A', 'rls-test-a');
    perform set_config('palestria.org_a', v_org::text, false);  -- false = session-level
end $$;

do $$
declare v_org uuid;
begin
    perform set_config(
        'request.jwt.claims',
        '{"sub":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"authenticated","app_metadata":{}}',
        true);
    v_org := create_organization('RLS Test Studio B', 'rls-test-b');
    perform set_config('palestria.org_b', v_org::text, false);
end $$;

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 3 — DATI org-scoped REALI in ENTRAMBE le org (come postgres).
-- Popoliamo per OGNI org: profiles (PII), payments (ledger), client_packages
-- (carnet) e una booking confermata sullo STESSO slot/data. In più, per ENTRAMBE
-- seediamo la configurazione di slot (time_slots_config + template attivo +
-- weekly_template_slots su 'group-class') così resolve_slot_config ritorna
-- capacity=12/bookable=true: la disponibilità riflette una reale capienza e la
-- controprova positiva sulle RPC non dipende da un dettaglio fragile.
-- I profili usano gli stessi uid degli owner (PK = auth.users.id): un solo
-- profilo-cliente per org soddisfa le FK di packages/booking.
-- ──────────────────────────────────────────────────────────────────────────────
do $$
declare
    v_org_a    uuid := current_setting('palestria.org_a')::uuid;
    v_org_b    uuid := current_setting('palestria.org_b')::uuid;
    v_weekday  smallint := extract(dow from date '2099-01-15')::smallint;  -- 0=Domenica
    v_ts_a     uuid;
    v_ts_b     uuid;
    v_tpl_a    uuid;
    v_tpl_b    uuid;
    v_gc_a     uuid;
    v_gc_b     uuid;
begin
    -- profiles: l'owner di ciascuna org diventa anche profilo-cliente nella sua org
    insert into profiles (id, org_id, name, email)
        values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_org_a, 'Cliente A', 'rls-a@test.dev')
        on conflict (id) do nothing;
    insert into profiles (id, org_id, name, email)
        values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_org_b, 'Cliente B', 'rls-b@test.dev')
        on conflict (id) do nothing;

    -- payments: 1 riga per org (ledger). method/kind rispettano i CHECK.
    insert into payments (org_id, client_user_id, client_email, amount, method, kind)
        values (v_org_a, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-a@test.dev', 30, 'contanti', 'session');
    insert into payments (org_id, client_user_id, client_email, amount, method, kind)
        values (v_org_b, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'rls-b@test.dev', 50, 'carta', 'session');

    -- client_packages: 1 carnet per org (total/remaining NOT NULL).
    insert into client_packages (org_id, user_id, label, total_sessions, remaining_sessions)
        values (v_org_a, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Carnet A', 10, 10);
    insert into client_packages (org_id, user_id, label, total_sessions, remaining_sessions)
        values (v_org_b, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Carnet B', 10, 10);

    -- slot_type 'group-class' (creato da create_organization) per ciascuna org
    select id into v_gc_a from slot_types where org_id = v_org_a and key = 'group-class';
    select id into v_gc_b from slot_types where org_id = v_org_b and key = 'group-class';

    -- configurazione slot 09:00-10:00 + template + mapping al group-class +
    -- ATTIVAZIONE della settimana che contiene il 2099-01-15, per ENTRAMBE le org
    -- → resolve_slot_config ritorna capacity=12/bookable=true. Dalla migration
    -- 00000000000020 la risoluzione passa da activated_weeks (non più dal solo
    -- is_active del template), quindi senza attivare la settimana la capienza sarebbe 0.
    insert into time_slots_config (org_id, start_time, end_time, label)
        values (v_org_a, time '09:00', time '10:00', 'Mattina') returning id into v_ts_a;
    insert into time_slots_config (org_id, start_time, end_time, label)
        values (v_org_b, time '09:00', time '10:00', 'Mattina') returning id into v_ts_b;

    insert into weekly_schedule_templates (org_id, name, is_active)
        values (v_org_a, 'Default A', true) returning id into v_tpl_a;
    insert into weekly_schedule_templates (org_id, name, is_active)
        values (v_org_b, 'Default B', true) returning id into v_tpl_b;

    insert into weekly_template_slots (template_id, org_id, weekday, time_slot_id, slot_type_id, capacity)
        values (v_tpl_a, v_org_a, v_weekday, v_ts_a, v_gc_a, 12);
    insert into weekly_template_slots (template_id, org_id, weekday, time_slot_id, slot_type_id, capacity)
        values (v_tpl_b, v_org_b, v_weekday, v_ts_b, v_gc_b, 12);

    -- Attiva la settimana del 2099-01-15 sul template di ciascuna org. Guard
    -- `to_regclass`: se gira solo la baseline (senza la migration 20) la tabella
    -- non esiste → si salta (il blocco RPC più sotto ha già la sua SKIP-guard).
    -- week_start calcolato con la STESSA espressione di resolve_slot_config (lunedì).
    if to_regclass('public.activated_weeks') is not null then
        insert into activated_weeks (org_id, week_start, template_id)
            values (v_org_a, date_trunc('week', date '2099-01-15'::timestamp)::date, v_tpl_a)
            on conflict (org_id, week_start) do nothing;
        insert into activated_weeks (org_id, week_start, template_id)
            values (v_org_b, date_trunc('week', date '2099-01-15'::timestamp)::date, v_tpl_b)
            on conflict (org_id, week_start) do nothing;
    end if;

    -- booking confermata sullo STESSO slot/data in ENTRAMBE le org. Serve a provare
    -- che le RPC pubbliche scoped-per-slug contino SOLO la org dello slug richiesto
    -- (1, non 2) e non mescolino le due org.
    insert into bookings (org_id, user_id, slot_type_id, date, time, slot_type, name, email, status)
        values (v_org_a, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_gc_a,
                date '2099-01-15', '09:00 - 10:00', 'group-class', 'Cliente A',
                'rls-a@test.dev', 'confirmed');
    insert into bookings (org_id, user_id, slot_type_id, date, time, slot_type, name, email, status)
        values (v_org_b, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', v_gc_b,
                date '2099-01-15', '09:00 - 10:00', 'group-class', 'Cliente B',
                'rls-b@test.dev', 'confirmed');
end $$;

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 4 — TEST DI ISOLAMENTO, direzione A → B
-- Sessione del membro/owner della org A: prima i claim (sub=uid_a, org_id=org_a),
-- POI SET LOCAL ROLE authenticated (solo allora RLS si applica). Tutto in una sola
-- transazione perché set_config(…,true)/SET LOCAL valgono solo qui. Gli id delle
-- org si leggono dalle GUC di sessione `palestria.org_a/b` (no temp table): il
-- ruolo authenticated può leggere le GUC con current_setting() senza alcun GRANT.
-- ──────────────────────────────────────────────────────────────────────────────
begin;
    select set_config(
        'request.jwt.claims',
        json_build_object(
            'sub',  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            'role', 'authenticated',
            'app_metadata', json_build_object(
                'org_id',   current_setting('palestria.org_a'),
                'org_role', 'owner'
            )
        )::text,
        true);

    set local role authenticated;

    -- (a) SELECT: vede SOLO la org A (guardia anti-false-pass) e MAI righe di B.
    do $$
    declare
        v_org_b uuid := current_setting('palestria.org_b')::uuid;
        v_own   int;
        v_other int;
    begin
        -- profiles
        select count(*) into v_own   from profiles;                       -- solo org A
        select count(*) into v_other from profiles where org_id = v_org_b;
        if v_own < 1 then
            raise exception 'A->B SELECT: il membro A non vede i propri profiles (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'A->B LEAK: il membro A vede % profiles della org B', v_other;
        end if;

        -- payments
        select count(*) into v_own   from payments;
        select count(*) into v_other from payments where org_id = v_org_b;
        if v_own < 1 then
            raise exception 'A->B SELECT: il membro A non vede i propri payments (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'A->B LEAK: il membro A vede % payments della org B', v_other;
        end if;

        -- client_packages
        select count(*) into v_own   from client_packages;
        select count(*) into v_other from client_packages where org_id = v_org_b;
        if v_own < 1 then
            raise exception 'A->B SELECT: il membro A non vede i propri client_packages (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'A->B LEAK: il membro A vede % client_packages della org B', v_other;
        end if;

        -- bookings
        select count(*) into v_own   from bookings;
        select count(*) into v_other from bookings where org_id = v_org_b;
        if v_own < 1 then
            raise exception 'A->B SELECT: il membro A non vede le proprie bookings (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'A->B LEAK: il membro A vede % bookings della org B', v_other;
        end if;
    end $$;

    -- (b) UPDATE su righe della org B → 0 righe toccate (RLS le rende invisibili).
    do $$
    declare v_org_b uuid := current_setting('palestria.org_b')::uuid; v_cnt int;
    begin
        update payments set note = 'tentativo-cross-org' where org_id = v_org_b;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'A->B LEAK: UPDATE ha toccato % payments della org B (atteso 0)', v_cnt;
        end if;

        update profiles set name = 'hacked' where org_id = v_org_b;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'A->B LEAK: UPDATE ha toccato % profiles della org B (atteso 0)', v_cnt;
        end if;
    end $$;

    -- (c) DELETE su righe della org B → 0 righe toccate.
    do $$
    declare v_org_b uuid := current_setting('palestria.org_b')::uuid; v_cnt int;
    begin
        delete from payments where org_id = v_org_b;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'A->B LEAK: DELETE ha rimosso % payments della org B (atteso 0)', v_cnt;
        end if;

        delete from client_packages where org_id = v_org_b;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'A->B LEAK: DELETE ha rimosso % client_packages della org B (atteso 0)', v_cnt;
        end if;
    end $$;

    -- (d) INSERT con org_id della org B → deve violare la WITH CHECK (RLS).
    --     La violazione di una WITH CHECK RLS è SEMPRE SQLSTATE 42501
    --     (insufficient_privilege), mai 23514 (check_violation). Catturiamo SOLO
    --     42501 e falliamo se l'insert riesce — così un'eventuale violazione di
    --     CHECK di colonna (bug nei dati di test) emergerebbe come errore reale.
    --     Testiamo TRE tabelle con WITH CHECK org-scoped (payments/profiles/packages).
    do $$
    declare v_org_b uuid := current_setting('palestria.org_b')::uuid;
    begin
        -- payments
        begin
            insert into payments (org_id, amount, method, kind, client_email)
                values (v_org_b, 99, 'contanti', 'session', 'leak@test.dev');
            raise exception 'A->B LEAK: INSERT in payments con org_id della org B è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;  -- atteso: policy WITH CHECK
        end;

        -- profiles (id arbitrario, non collide con gli owner)
        begin
            insert into profiles (id, org_id, name, email)
                values ('cccccccc-cccc-cccc-cccc-cccccccccccc', v_org_b, 'Leak', 'leak2@test.dev');
            raise exception 'A->B LEAK: INSERT in profiles con org_id della org B è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;
        end;

        -- client_packages
        begin
            insert into client_packages (org_id, user_id, label, total_sessions, remaining_sessions)
                values (v_org_b, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Leak', 5, 5);
            raise exception 'A->B LEAK: INSERT in client_packages con org_id della org B è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;
        end;
    end $$;

    -- (e) RPC pubbliche org-scoped per-slug: con ENTRAMBE le org che hanno una
    --     booking sullo stesso slot/data, la RPC chiamata con uno slug deve contare
    --     SOLO la org di quello slug (1, non 2). Questo rileva un eventuale mancato
    --     filtro per org. Le RPC vivono nelle migration operative (00000000000001):
    --     se assenti (es. run contro solo-baseline) il blocco si salta in modo
    --     pulito invece di abortire con 42883 undefined_function.
    --     NB: queste RPC sono SECURITY DEFINER e pubbliche per design (anche anon),
    --     scoped per p_org_slug → ritornano SOLO aggregati (capienza/iscritti, no
    --     PII). La prova di isolamento "vero" via RLS è (a)/(b)/(c)/(d)+(f); qui
    --     verifichiamo il CONTRATTO di scoping: nessuno slug mischia due org.
    do $$
    declare
        v_avail jsonb;
        v_cnt_a int;
        v_att_a int;
        v_att_b int;
    begin
        if to_regprocedure('get_availability_range(text,date,date)') is null
           or to_regprocedure('get_slot_attendees(text,date,text)') is null then
            raise notice 'SKIP RPC test (A->B): get_availability_range/get_slot_attendees non presenti (solo baseline)';
            return;
        end if;

        -- get_availability_range(slug A): deve contenere lo slot 09:00-10:00 con
        -- confirmed_count = 1 (solo la booking di A), capacity 12.
        v_avail := get_availability_range('rls-test-a', date '2099-01-01', date '2099-12-31');
        if v_avail is null or jsonb_array_length(v_avail) = 0 then
            raise exception 'RPC: get_availability_range(slug A) doveva esporre la booking di A, ha restituito: %', v_avail;
        end if;
        select (e->>'confirmed_count')::int into v_cnt_a
        from jsonb_array_elements(v_avail) e
        where e->>'time' = '09:00 - 10:00' and e->>'slot_type' = 'group-class';
        if v_cnt_a is distinct from 1 then
            raise exception 'RPC LEAK: get_availability_range(slug A) conta % confermati sullo slot (atteso 1, NON deve includere la booking di B)', v_cnt_a;
        end if;

        -- get_slot_attendees: SLUG A → 1 iscritto (Cliente A); SLUG B → 1 (Cliente B).
        -- Controllo POSITIVO + negativo: nessuno slug deve restituire 2 (mix org).
        select count(*) into v_att_a
        from get_slot_attendees('rls-test-a', date '2099-01-15', '09:00 - 10:00');
        if v_att_a <> 1 then
            raise exception 'RPC LEAK: get_slot_attendees(slug A) ha % iscritti (atteso esattamente 1)', v_att_a;
        end if;
        select count(*) into v_att_b
        from get_slot_attendees('rls-test-b', date '2099-01-15', '09:00 - 10:00');
        if v_att_b <> 1 then
            raise exception 'RPC LEAK: get_slot_attendees(slug B) ha % iscritti (atteso esattamente 1, NON deve includere A)', v_att_b;
        end if;
    end $$;

    -- (f) RPC autenticata org-scoped via current_org_id(): impersonando A,
    --     get_all_profiles() (se presente) deve ritornare SOLO i profili di A,
    --     senza alcun parametro che permetta di scavalcare current_org_id().
    --     Questa È una prova di isolamento sulle RPC (a differenza di (e), che è il
    --     contratto delle RPC pubbliche per-slug).
    do $$
    declare v_n int;
    begin
        if to_regprocedure('get_all_profiles()') is null then
            raise notice 'SKIP RPC test (A->B): get_all_profiles non presente (solo baseline)';
            return;
        end if;
        select count(*) into v_n from get_all_profiles();
        if v_n <> 1 then
            raise exception 'RPC LEAK: get_all_profiles() (membro A) ha restituito % profili (atteso 1, solo org A)', v_n;
        end if;
        if not exists (select 1 from get_all_profiles() where email = 'rls-a@test.dev') then
            raise exception 'RPC: get_all_profiles() (membro A) non contiene il profilo di A';
        end if;
        if exists (select 1 from get_all_profiles() where email = 'rls-b@test.dev') then
            raise exception 'RPC LEAK: get_all_profiles() (membro A) contiene un profilo della org B';
        end if;
    end $$;

    reset role;
rollback;  -- nessun side-effect persistente dalle asserzioni (gli UPDATE/DELETE
           -- sono comunque a 0 righe; rollback per pulizia/idempotenza).

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 5 — TEST DI ISOLAMENTO, direzione SPECULARE B → A
-- Stessa struttura, impersonando l'owner della org B.
-- ──────────────────────────────────────────────────────────────────────────────
begin;
    select set_config(
        'request.jwt.claims',
        json_build_object(
            'sub',  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            'role', 'authenticated',
            'app_metadata', json_build_object(
                'org_id',   current_setting('palestria.org_b'),
                'org_role', 'owner'
            )
        )::text,
        true);

    set local role authenticated;

    -- (a) SELECT: vede SOLO la org B e MAI righe di A.
    do $$
    declare
        v_org_a uuid := current_setting('palestria.org_a')::uuid;
        v_own   int;
        v_other int;
    begin
        select count(*) into v_own   from profiles;
        select count(*) into v_other from profiles where org_id = v_org_a;
        if v_own < 1 then
            raise exception 'B->A SELECT: il membro B non vede i propri profiles (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'B->A LEAK: il membro B vede % profiles della org A', v_other;
        end if;

        select count(*) into v_own   from payments;
        select count(*) into v_other from payments where org_id = v_org_a;
        if v_own < 1 then
            raise exception 'B->A SELECT: il membro B non vede i propri payments (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'B->A LEAK: il membro B vede % payments della org A', v_other;
        end if;

        select count(*) into v_own   from client_packages;
        select count(*) into v_other from client_packages where org_id = v_org_a;
        if v_own < 1 then
            raise exception 'B->A SELECT: il membro B non vede i propri client_packages (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'B->A LEAK: il membro B vede % client_packages della org A', v_other;
        end if;

        select count(*) into v_own   from bookings;
        select count(*) into v_other from bookings where org_id = v_org_a;
        if v_own < 1 then
            raise exception 'B->A SELECT: il membro B non vede le proprie bookings (atteso >=1, trovato %)', v_own;
        end if;
        if v_other <> 0 then
            raise exception 'B->A LEAK: il membro B vede % bookings della org A', v_other;
        end if;
    end $$;

    -- (b) UPDATE su righe della org A → 0 righe.
    do $$
    declare v_org_a uuid := current_setting('palestria.org_a')::uuid; v_cnt int;
    begin
        update payments set note = 'tentativo-cross-org' where org_id = v_org_a;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'B->A LEAK: UPDATE ha toccato % payments della org A (atteso 0)', v_cnt;
        end if;

        update profiles set name = 'hacked' where org_id = v_org_a;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'B->A LEAK: UPDATE ha toccato % profiles della org A (atteso 0)', v_cnt;
        end if;
    end $$;

    -- (c) DELETE su righe della org A → 0 righe.
    do $$
    declare v_org_a uuid := current_setting('palestria.org_a')::uuid; v_cnt int;
    begin
        delete from payments where org_id = v_org_a;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'B->A LEAK: DELETE ha rimosso % payments della org A (atteso 0)', v_cnt;
        end if;

        delete from client_packages where org_id = v_org_a;
        get diagnostics v_cnt = row_count;
        if v_cnt <> 0 then
            raise exception 'B->A LEAK: DELETE ha rimosso % client_packages della org A (atteso 0)', v_cnt;
        end if;
    end $$;

    -- (d) INSERT con org_id della org A → deve violare la WITH CHECK (42501).
    do $$
    declare v_org_a uuid := current_setting('palestria.org_a')::uuid;
    begin
        begin
            insert into payments (org_id, amount, method, kind, client_email)
                values (v_org_a, 99, 'contanti', 'session', 'leak@test.dev');
            raise exception 'B->A LEAK: INSERT in payments con org_id della org A è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;
        end;

        begin
            insert into profiles (id, org_id, name, email)
                values ('dddddddd-dddd-dddd-dddd-dddddddddddd', v_org_a, 'Leak', 'leak3@test.dev');
            raise exception 'B->A LEAK: INSERT in profiles con org_id della org A è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;
        end;

        begin
            insert into client_packages (org_id, user_id, label, total_sessions, remaining_sessions)
                values (v_org_a, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Leak', 5, 5);
            raise exception 'B->A LEAK: INSERT in client_packages con org_id della org A è RIUSCITA (atteso: violazione RLS)';
        exception
            when insufficient_privilege then null;
        end;
    end $$;

    -- (e) RPC pubbliche per-slug: simmetrico — ogni slug conta SOLO la propria org.
    do $$
    declare
        v_avail jsonb;
        v_cnt_b int;
        v_att_a int;
        v_att_b int;
    begin
        if to_regprocedure('get_availability_range(text,date,date)') is null
           or to_regprocedure('get_slot_attendees(text,date,text)') is null then
            raise notice 'SKIP RPC test (B->A): get_availability_range/get_slot_attendees non presenti (solo baseline)';
            return;
        end if;

        v_avail := get_availability_range('rls-test-b', date '2099-01-01', date '2099-12-31');
        if v_avail is null or jsonb_array_length(v_avail) = 0 then
            raise exception 'RPC: get_availability_range(slug B) doveva esporre la booking di B, ha restituito: %', v_avail;
        end if;
        select (e->>'confirmed_count')::int into v_cnt_b
        from jsonb_array_elements(v_avail) e
        where e->>'time' = '09:00 - 10:00' and e->>'slot_type' = 'group-class';
        if v_cnt_b is distinct from 1 then
            raise exception 'RPC LEAK: get_availability_range(slug B) conta % confermati sullo slot (atteso 1, NON deve includere la booking di A)', v_cnt_b;
        end if;

        select count(*) into v_att_a
        from get_slot_attendees('rls-test-a', date '2099-01-15', '09:00 - 10:00');
        if v_att_a <> 1 then
            raise exception 'RPC LEAK: get_slot_attendees(slug A) ha % iscritti (atteso esattamente 1)', v_att_a;
        end if;
        select count(*) into v_att_b
        from get_slot_attendees('rls-test-b', date '2099-01-15', '09:00 - 10:00');
        if v_att_b <> 1 then
            raise exception 'RPC LEAK: get_slot_attendees(slug B) ha % iscritti (atteso esattamente 1, NON deve includere A)', v_att_b;
        end if;
    end $$;

    -- (f) RPC autenticata org-scoped: get_all_profiles() (membro B) → solo org B.
    do $$
    declare v_n int;
    begin
        if to_regprocedure('get_all_profiles()') is null then
            raise notice 'SKIP RPC test (B->A): get_all_profiles non presente (solo baseline)';
            return;
        end if;
        select count(*) into v_n from get_all_profiles();
        if v_n <> 1 then
            raise exception 'RPC LEAK: get_all_profiles() (membro B) ha restituito % profili (atteso 1, solo org B)', v_n;
        end if;
        if not exists (select 1 from get_all_profiles() where email = 'rls-b@test.dev') then
            raise exception 'RPC: get_all_profiles() (membro B) non contiene il profilo di B';
        end if;
        if exists (select 1 from get_all_profiles() where email = 'rls-a@test.dev') then
            raise exception 'RPC LEAK: get_all_profiles() (membro B) contiene un profilo della org A';
        end if;
    end $$;

    reset role;
rollback;

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 6 — CONTROPROVA POSITIVA SU WITH CHECK (path "felice", come authenticated).
-- Non basta provare che le scritture cross-org FALLISCONO: verifichiamo anche che
-- una scrittura org-scoped LEGITTIMA (nella PROPRIA org, da admin) RIESCA. Così
-- escludiamo che la WITH CHECK stia bloccando TUTTO indiscriminatamente (che
-- darebbe falsi "pass" su b/c/d della FASE 4/5). Usiamo un INSERT diretto su
-- payments della propria org e la RPC org-aware upsert_org_setting; rollback per
-- non lasciare residui.
-- ──────────────────────────────────────────────────────────────────────────────
begin;
    select set_config(
        'request.jwt.claims',
        json_build_object(
            'sub',  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            'role', 'authenticated',
            'app_metadata', json_build_object(
                'org_id',   current_setting('palestria.org_a'),
                'org_role', 'owner'
            )
        )::text,
        true);

    set local role authenticated;

    do $$
    declare v_org_a uuid := current_setting('palestria.org_a')::uuid; v_cnt int;
    begin
        -- INSERT legittimo nella PROPRIA org → deve riuscire (WITH CHECK passa).
        insert into payments (org_id, client_user_id, client_email, amount, method, kind)
            values (v_org_a, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'rls-a@test.dev', 12, 'contanti', 'session');
        get diagnostics v_cnt = row_count;
        if v_cnt <> 1 then
            raise exception 'POSITIVO: INSERT payments nella propria org A doveva riuscire (1 riga), inserite %', v_cnt;
        end if;

        -- RPC org-aware upsert_org_setting (se presente) → scrive nella propria org.
        if to_regprocedure('upsert_org_setting(text,jsonb)') is not null then
            perform upsert_org_setting('test.rls_positive', to_jsonb('ok'::text));
            if not exists (
                select 1 from org_settings
                where org_id = v_org_a and key = 'test.rls_positive'
            ) then
                raise exception 'POSITIVO: upsert_org_setting non ha scritto nella propria org A';
            end if;
        end if;
    end $$;

    reset role;
rollback;

-- ──────────────────────────────────────────────────────────────────────────────
-- FASE 7 — PULIZIA FINALE (come postgres): rimuove org e utenti di test.
-- Lo script resta idempotente anche grazie alla FASE 0, ma ripuliamo subito così
-- non lasciamo dati di test nel DB della CI. La org demo del seed resta intatta.
-- ──────────────────────────────────────────────────────────────────────────────
delete from organizations where slug in ('rls-test-a', 'rls-test-b');
delete from auth.users
 where id in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
              'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
-- rilascia le GUC di sessione (cosmetico: la sessione psql termina comunque qui).
select set_config('palestria.org_a', '', false);
select set_config('palestria.org_b', '', false);

-- ──────────────────────────────────────────────────────────────────────────────
-- ESITO
-- ──────────────────────────────────────────────────────────────────────────────
do $$
begin
    raise notice 'OK: RLS cross-tenant isolation verified';
end $$;
