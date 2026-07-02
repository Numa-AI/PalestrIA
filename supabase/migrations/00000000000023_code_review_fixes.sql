-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000023_code_review_fixes
--
-- Port (adattato al multi-tenant SaaS) dei fix DB della "code review 1" nati sul
-- gemello single-tenant Thomas Bresciani. Molti finding del pacchetto originale sono
-- GIÀ coperti dalla baseline SaaS o NON APPLICABILI (sistema crediti rimosso):
--   • 1.1 bookings RLS write-only-admin  → GIÀ in baseline (bookings_admin_write)
--   • 1.3 workout_logs.rest_done + RLS   → GIÀ in baseline
--   • 1.4 admin_duplicate_plan.circuit_group → GIÀ in 00000000000001
--   • 1.6 restore credit_history / 1.9 stripe_topup_credit → N/A (crediti rimossi)
--   • 1.5 token tablet (QR opaco a scadenza) → RIMANDATO a task dedicato (cantiere
--         DB org-aware + adattamento delle RPC kiosk_*). Non incluso qui.
--
-- Questa migration porta i 3 fix DB realmente applicabili, in forma incrementale
-- sopra la baseline già applicata sul remoto (NON ri-applicare la baseline):
--   1.2  profiles: trigger anti self-update del flag admin-only `documento_firmato`
--        (stripe_enabled / autonomia_enabled del gemello NON esistono qui → esclusi)
--   1.7  admin_delete_client_data: firma email+whatsapp, delete cliente esteso alle
--        tabelle billing/notifiche (payments preservato = ledger fatturato)
--   1.8  admin_prune_old_data(cutoff): prune server-side org-scoped (niente credit_history)
--
-- Idempotente e rieseguibile. Pattern grant come 00000000000022 (revoke public/anon +
-- grant authenticated); nessuna RPC concessa ad anon. Il CLI Supabase avvolge già ogni
-- migration in una transazione: nessun begin/commit esplicito (come le altre migration).
-- ──────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.2 — profiles: blocca l'auto-assegnazione dei flag admin-only
--
-- La policy `profiles_update` permette al cliente di aggiornare la PROPRIA riga
-- (id = auth.uid()), inclusi campi legittimamente self-owned (privacy_prenotazioni,
-- push_enabled, geo_enabled). Ma `documento_firmato` è un flag ADMIN-ONLY: in
-- PalestrIA è scritto SOLO dai flussi admin (admin-clients.js / restore backup);
-- nessun flusso cliente lo firma da sé. Senza guardia, un utente potrebbe segnarsi
-- `documento_firmato=true` via PostgREST. Il trigger lascia fare tutto all'admin
-- della org e, per il non-admin, ripristina silenziosamente il valore precedente
-- (revert non-distruttivo: un self-update legittimo che includa la colonna nel
-- payload non va in errore, semplicemente non la cambia).
--
-- Nota multi-tenant: `stripe_enabled` / `autonomia_enabled` del gemello NON esistono
-- nella tabella profiles SaaS → protetto il solo flag presente.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function _trg_profiles_block_self_admin_flags()
returns trigger language plpgsql security definer set search_path = public as $$
begin
    if new.documento_firmato is distinct from old.documento_firmato
       and not is_org_admin(old.org_id) then
        new.documento_firmato := old.documento_firmato;
    end if;
    return new;
end;
$$;

drop trigger if exists trg_profiles_block_self_admin_flags on profiles;
create trigger trg_profiles_block_self_admin_flags
    before update on profiles
    for each row execute function _trg_profiles_block_self_admin_flags();
-- Coerenza con l'hardening di 00000000000022 (che gira PRIMA e non vede questa funzione):
-- togli l'EXECUTE di default a public/anon. Il trigger continua a scattare comunque
-- (le trigger function non richiedono EXECUTE); una chiamata diretta via REST fallisce.
revoke all on function _trg_profiles_block_self_admin_flags() from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.7 — admin_delete_client_data: firma email+whatsapp + delete esteso
--
-- Prima: firma solo (p_email) → un cliente registrato solo con WhatsApp non veniva
-- cancellato server-side; e la cancellazione toccava solo `bookings`, lasciando
-- membership/pacchetti/override billing/notifiche.
-- Ora: accetta email e/o whatsapp (match come admin_rename_client), cancella le
-- prenotazioni e gli artefatti billing del cliente. `payments` NON viene toccato
-- (è il ledger del fatturato; payments.client_user_id/booking_id sono ON DELETE
-- SET NULL, lo storico incassi resta). La riga `profiles` NON viene eliminata:
-- questo è un "reset dati operativi", non la cancellazione dell'account.
--
-- Le tabelle billing/notifiche sono chiavate su user_id → risolvo prima gli id dei
-- profili corrispondenti (per email o whatsapp), poi cancello per user_id.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists admin_delete_client_data(text);
create or replace function admin_delete_client_data(
    p_email    text default null,
    p_whatsapp text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_org   uuid := current_org_id();
    v_mail  text := lower(trim(coalesce(p_email, '')));
    v_wa    text := nullif(trim(coalesce(p_whatsapp, '')), '');
    v_uids  uuid[];
    v_book  integer := 0;
    v_mem   integer := 0;
    v_pkg   integer := 0;
    v_bp    integer := 0;
    v_notif integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    if v_mail = '' and v_wa is null then
        return jsonb_build_object('success', false, 'error', 'missing_email_or_whatsapp');
    end if;

    -- profili del cliente nella org (per cancellare gli artefatti chiavati su user_id)
    select coalesce(array_agg(id), '{}')
      into v_uids
      from profiles
     where org_id = v_org
       and ( (v_mail <> '' and lower(email) = v_mail)
             or (v_wa is not null and whatsapp = v_wa) );

    -- prenotazioni (match su email o whatsapp, come sono memorizzate sulla riga booking)
    delete from bookings
     where org_id = v_org
       and ( (v_mail <> '' and lower(email) = v_mail)
             or (v_wa is not null and whatsapp = v_wa) );
    get diagnostics v_book = row_count;

    if array_length(v_uids, 1) is not null then
        delete from client_memberships where org_id = v_org and user_id = any(v_uids);
        get diagnostics v_mem = row_count;

        delete from client_packages where org_id = v_org and user_id = any(v_uids);
        get diagnostics v_pkg = row_count;

        delete from client_notifications where org_id = v_org and user_id = any(v_uids);
        get diagnostics v_notif = row_count;
    end if;

    -- override billing: chiavato su user_id (unique org,user) ma anche client_email
    delete from client_billing_profiles
     where org_id = v_org
       and ( (array_length(v_uids, 1) is not null and user_id = any(v_uids))
             or (v_mail <> '' and lower(coalesce(client_email, '')) = v_mail) );
    get diagnostics v_bp = row_count;

    return jsonb_build_object(
        'success', true,
        'bookings_deleted', v_book,
        'memberships_deleted', v_mem,
        'packages_deleted', v_pkg,
        'billing_profiles_deleted', v_bp,
        'notifications_deleted', v_notif
    );
end;
$$;
revoke all on function admin_delete_client_data(text, text) from public, anon;
grant execute on function admin_delete_client_data(text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1.8 — admin_prune_old_data(cutoff): prune storico server-side org-scoped
--
-- Prima il prune del backup admin puliva solo le cache locali: al reload i dati
-- vecchi tornavano da Supabase. Questa RPC cancella davvero, lato server e nella
-- sola org corrente, le prenotazioni con `date < cutoff` più le prenotazioni demo
-- (`local_id like 'demo-%'`). NON tocca `payments` (ledger fatturato) né altre
-- tabelle: i saldi correnti restano invariati. (Nel gemello cancellava anche
-- credit_history: N/A qui, tabella rimossa.)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function admin_prune_old_data(p_cutoff date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_org  uuid := current_org_id();
    v_old  integer := 0;
    v_demo integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    if p_cutoff is null then
        return jsonb_build_object('success', false, 'error', 'missing_cutoff');
    end if;

    delete from bookings where org_id = v_org and date < p_cutoff;
    get diagnostics v_old = row_count;

    delete from bookings where org_id = v_org and local_id like 'demo-%';
    get diagnostics v_demo = row_count;

    return jsonb_build_object('success', true, 'bookings_deleted', v_old, 'demo_deleted', v_demo);
end;
$$;
revoke all on function admin_prune_old_data(date) from public, anon;
grant execute on function admin_prune_old_data(date) to authenticated;
