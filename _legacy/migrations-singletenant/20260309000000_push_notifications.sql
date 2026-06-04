-- ─── PUSH NOTIFICATIONS ──────────────────────────────────────────────────────
-- Aggiunge colonna reminder_1h_sent a bookings e RPC save_push_subscription

-- Colonna per tracciare se il promemoria 1h è già stato inviato
alter table bookings
    add column if not exists reminder_1h_sent boolean not null default false;

-- ─── RPC: save_push_subscription ─────────────────────────────────────────────
-- Salva (UPSERT) la subscription push dell'utente autenticato.
-- SECURITY DEFINER: bypassa RLS; usa auth.uid() come user_id.
-- Se si passa p_user_id, viene usato in fallback (per debug/admin).
create or replace function save_push_subscription(
    p_endpoint   text,
    p_p256dh     text,
    p_auth       text,
    p_user_email text default null,
    p_user_id    uuid default null
)
returns void language plpgsql security definer as $$
declare
    v_user_id uuid;
begin
    -- Usa l'utente autenticato dalla sessione JWT
    v_user_id := auth.uid();

    -- Fallback al parametro esplicito (es. chiamata da Edge Function)
    if v_user_id is null then
        v_user_id := p_user_id;
    end if;

    if v_user_id is null then
        raise exception 'save_push_subscription: utente non autenticato';
    end if;

    insert into push_subscriptions (user_id, endpoint, p256dh, auth)
    values (v_user_id, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
        set user_id    = v_user_id,
            p256dh     = excluded.p256dh,
            auth       = excluded.auth;
end;
$$;
