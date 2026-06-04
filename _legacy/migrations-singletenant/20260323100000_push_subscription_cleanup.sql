-- ─── PUSH SUBSCRIPTION: pulizia endpoint stale ─────────────────────────────
-- Quando un utente reinstalla l'app o cancella la cache, il browser genera
-- un nuovo endpoint. La vecchia riga nel DB con l'endpoint morto resta lì
-- e le notifiche non arrivano più. Questa migration aggiorna la RPC per
-- eliminare le subscription vecchie dello stesso push-service origin
-- (stesso dispositivo, endpoint diverso) quando ne viene salvata una nuova.

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
    v_origin  text;
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

    -- Estrai l'origin del push service (es. https://fcm.googleapis.com)
    -- Le subscription dello stesso dispositivo condividono lo stesso origin.
    -- Quando il browser rinnova la subscription, l'origin resta uguale ma il path cambia.
    v_origin := substring(p_endpoint from '^https?://[^/]+');

    -- Elimina le vecchie subscription dello stesso utente + stesso push-service origin
    -- (= stesso dispositivo/browser) ma con endpoint diverso (= subscription scaduta)
    if v_origin is not null then
        delete from push_subscriptions
        where user_id  = v_user_id
          and endpoint <> p_endpoint
          and endpoint like v_origin || '%';
    end if;

    -- Upsert la nuova subscription
    insert into push_subscriptions (user_id, endpoint, p256dh, auth)
    values (v_user_id, p_endpoint, p_p256dh, p_auth)
    on conflict (endpoint) do update
        set user_id    = v_user_id,
            p256dh     = excluded.p256dh,
            auth       = excluded.auth;
end;
$$;
