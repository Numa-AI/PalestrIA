-- Impedisce la registrazione di più utenti con lo stesso numero WhatsApp.
-- I valori vuoti ('') vengono ignorati (partial index) così non bloccano utenti senza numero.
create unique index if not exists profiles_whatsapp_unique
    on profiles (whatsapp)
    where whatsapp is not null and whatsapp <> '';

-- Funzione RPC pubblica per verificare se un numero WhatsApp è già in uso.
-- Utilizzabile da utenti anonimi (durante la registrazione) senza esporre dati sensibili.
-- Ritorna solo true/false, mai dati del profilo.
create or replace function public.is_whatsapp_taken(phone text, exclude_user_id uuid default null)
returns boolean
language sql security definer stable
set search_path = public
as $$
    select exists (
        select 1 from profiles
        where whatsapp = phone
          and whatsapp <> ''
          and (exclude_user_id is null or id <> exclude_user_id)
    );
$$;

-- Permetti chiamate anonime e autenticate
grant execute on function public.is_whatsapp_taken(text, uuid) to anon, authenticated;
