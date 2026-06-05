-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — Fix post-deploy (round 1)
-- RPC/colonne/policy mancanti emerse al primo test del frontend sul nuovo progetto.
-- Tutto org-scoped, idempotente.
-- ══════════════════════════════════════════════════════════════════════════════

-- ── login_events: colonne device-analytics + policy INSERT ────────────────────
alter table login_events
    add column if not exists event_type  text,
    add column if not exists device_hash text,
    add column if not exists user_agent  text,
    add column if not exists platform    text,
    add column if not exists browser     text,
    add column if not exists screen_size text,
    add column if not exists timezone    text,
    add column if not exists language    text,
    add column if not exists is_pwa      boolean;

-- ogni utente autenticato registra i PROPRI eventi di login (org_id può essere null pre-onboarding)
drop policy if exists login_events_insert on login_events;
create policy login_events_insert on login_events
    for insert to authenticated
    with check (user_id = auth.uid());

-- ── Push: salva subscription + elenco utenti con push attivo ──────────────────
create or replace function save_push_subscription(
    p_endpoint text, p_p256dh text, p_auth text,
    p_user_email text default null, p_user_id uuid default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_uid uuid := coalesce(p_user_id, auth.uid());
begin
    if v_org is null or v_uid is null then return; end if;  -- niente org/utente → skip
    insert into push_subscriptions (org_id, user_id, endpoint, p256dh, auth)
        values (v_org, v_uid, p_endpoint, p_p256dh, p_auth)
        on conflict (endpoint) do update
            set p256dh = excluded.p256dh, auth = excluded.auth,
                user_id = excluded.user_id, org_id = excluded.org_id;
end;
$$;
revoke all on function save_push_subscription(text,text,text,text,uuid) from public, anon;
grant execute on function save_push_subscription(text,text,text,text,uuid) to authenticated;

-- elenco (scalare) degli user_id con push attivo nella propria org (per le notifiche admin)
create or replace function get_push_enabled_users()
returns setof uuid language sql stable security definer set search_path = public as $$
    select p.id from profiles p where p.org_id = current_org_id() and p.push_enabled
$$;
revoke all on function get_push_enabled_users() from public, anon;
grant execute on function get_push_enabled_users() to authenticated;

-- ── Consenso report AI (per-cliente) ──────────────────────────────────────────
alter table profiles add column if not exists report_ai_consent boolean not null default false;

create or replace function set_report_ai_consent(p_consent boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
    update profiles set report_ai_consent = coalesce(p_consent, true) where id = auth.uid();
end;
$$;
revoke all on function set_report_ai_consent(boolean) from public, anon;
grant execute on function set_report_ai_consent(boolean) to authenticated;

-- ── Health check / fix (stub org-scoped: nessuna anomalia "credito" da sanare) ─
-- Il vecchio health-check verificava crediti/debiti/bonus orfani (sistema rimosso).
-- Stub che ritorna "tutto ok" così la UI Sicurezza/Manutenzione non va in errore.
create or replace function admin_health_check()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    if not is_org_admin(current_org_id()) then raise exception 'unauthorized'; end if;
    return jsonb_build_object('success', true);
end;
$$;
revoke all on function admin_health_check() from public, anon;
grant execute on function admin_health_check() to authenticated;

create or replace function admin_health_fix()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
    if not is_org_admin(current_org_id()) then raise exception 'unauthorized'; end if;
    return jsonb_build_object('success', true);
end;
$$;
revoke all on function admin_health_fix() from public, anon;
grant execute on function admin_health_fix() to authenticated;
