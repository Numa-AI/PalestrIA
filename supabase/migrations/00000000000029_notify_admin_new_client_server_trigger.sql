-- ─────────────────────────────────────────────────────────────────────────────
-- 00000000000029 — Notifica admin "nuovo iscritto" lato SERVER (trigger + pg_net)
--
-- Contesto (port dal gemello Thomas, 2026-07-07). La push admin "🆕 New entry!"
-- dipendeva SOLO dal JavaScript nel browser del cliente appena registrato
-- (login.html → maybeNotifyNewClient → notifyAdminNewClient → Edge Function), che
-- scattava in una finestra fragile (created_at<120s, tab chiusa, flussi email vs
-- OAuth, PKCE, errori inghiottiti). È lo stesso approccio che qui si è già rotto
-- una volta (vedi todo.md, port 2026-07-04 "D fix notifica PKCE"): fix ricorrente
-- sullo stesso design → problema ARCHITETTURALE.
--
-- Fix: la notifica la fa partire il DATABASE. Quando un profilo cliente viene
-- creato (INSERT su public.profiles, da handle_new_user o join_organization) un
-- trigger AFTER INSERT invoca la Edge Function via pg_net. Nessuna dipendenza da
-- timing/browser/flusso. Se la function è giù, l'iscrizione riesce comunque
-- (pg_net è fire-and-forget, spedito dopo il commit). Multi-tenant: NEW.org_id è
-- già risolto qui, e l'Edge deriva org + nome server-side dal profilo (anti-spoof).
--
-- Idempotente. Da applicare a mano nel SQL Editor / `supabase db push`.
--
-- ⚠️ DEPLOY (obbligatorio, altrimenti la notifica non parte):
--   1) select gen_random_uuid();  → <VALORE>
--   2) select vault.create_secret('<VALORE>', 'new_client_notify_secret');
--   3) supabase secrets set NEW_CLIENT_NOTIFY_SECRET=<VALORE>
--   4) supabase functions deploy notify-admin-new-client --no-verify-jwt
--   5) applica questa migration
-- Il client (login.html/push.js) resta come FALLBACK; il dedup nell'Edge (5 min)
-- impedisce i doppioni tra canale server e client.
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists pg_net;

create or replace function public.notify_admin_new_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_created timestamptz;
    v_secret  text;
    -- URL della Edge Function (progetto Supabase di PalestrIA: rwaiekhllujximrqftmp).
    v_url     text := 'https://rwaiekhllujximrqftmp.supabase.co/functions/v1/notify-admin-new-client';
begin
    -- Guardia di freschezza: notifica solo iscrizioni recenti (evita di spammare
    -- su eventuali backfill/re-insert di profili vecchi). Il flusso normale crea
    -- il profilo entro pochi secondi dall'auth.users (handle_new_user al signup).
    select created_at into v_created from auth.users where id = new.id;
    if v_created is null or v_created < now() - interval '15 minutes' then
        return new;
    end if;

    -- Secret interno condiviso con la Edge (Vault). Se manca → skip silenzioso.
    select decrypted_secret into v_secret
      from vault.decrypted_secrets
     where name = 'new_client_notify_secret'
     limit 1;
    if v_secret is null then
        raise log '[notify_admin_new_client] secret Vault "new_client_notify_secret" mancante → notifica saltata';
        return new;
    end if;

    -- Fire-and-forget: l'Edge deriva org + nome dal profilo (user_id), il body è
    -- solo un fallback. Nessun Authorization Bearer: l'Edge autorizza via
    -- x-internal-secret (config verify_jwt=false).
    perform net.http_post(
        url     := v_url,
        body    := jsonb_build_object('name', new.name, 'user_id', new.id),
        headers := jsonb_build_object(
            'Content-Type',      'application/json',
            'x-internal-secret', v_secret
        )
    );

    return new;
exception when others then
    -- Non deve MAI abortire il signup: qualsiasi errore (pg_net assente, Vault,
    -- rete) viene loggato e ingoiato.
    raise log '[notify_admin_new_client] errore ingoiato: %', sqlerrm;
    return new;
end;
$$;

-- Trigger separato da handle_new_user per non toccare la logica critica di
-- creazione profilo. Fire on INSERT reale (handle_new_user usa on conflict do
-- nothing → niente trigger sui conflitti).
drop trigger if exists trg_notify_admin_new_client on public.profiles;
create trigger trg_notify_admin_new_client
    after insert on public.profiles
    for each row execute procedure public.notify_admin_new_client();
