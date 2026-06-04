-- ─── FIX: gli utenti normali non vedono i propri crediti ────────────────────
-- Le tabelle credits e credit_history avevano SOLO la policy admin_all.
-- Aggiungiamo SELECT policies per gli utenti autenticati sui propri record.

-- credits: l'utente può leggere il proprio record (match su user_id)
drop policy if exists "credits_select_own" on credits;
create policy "credits_select_own"
    on credits for select to authenticated
    using (user_id = auth.uid());

-- credit_history: l'utente può leggere lo storico dei propri crediti
-- (join tramite credit_id → credits.user_id)
drop policy if exists "credit_history_select_own" on credit_history;
create policy "credit_history_select_own"
    on credit_history for select to authenticated
    using (
        exists (
            select 1 from credits
            where credits.id = credit_history.credit_id
              and credits.user_id = auth.uid()
        )
    );

-- ─── TRIGGER: popola automaticamente user_id in credits da profiles ─────────
-- Quando l'admin inserisce/aggiorna credits senza user_id, il trigger
-- lo risolve automaticamente dall'email → profiles.
create or replace function auto_link_credit_user_id()
returns trigger language plpgsql security definer as $$
begin
    if new.user_id is null and new.email is not null then
        select id into new.user_id
        from profiles
        where email = new.email
        limit 1;
    end if;
    return new;
end;
$$;

drop trigger if exists credits_auto_link_user on credits;
create trigger credits_auto_link_user
    before insert or update on credits
    for each row execute function auto_link_credit_user_id();

-- ─── FIX: aggiorna i record credits esistenti che hanno user_id NULL ────────
update credits c
set user_id = p.id
from profiles p
where c.email = p.email
  and c.user_id is null;
