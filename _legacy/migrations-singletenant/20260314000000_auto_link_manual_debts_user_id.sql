-- ─── FIX: manual_debts non ha user_id → utenti non-admin non vedono i propri debiti ──
-- Stesso pattern del trigger auto_link_credit_user_id su credits.

-- 1. Trigger: popola automaticamente user_id da profiles.email
create or replace function auto_link_manual_debt_user_id()
returns trigger language plpgsql security definer as $$
begin
    if new.user_id is null and new.email is not null then
        select id into new.user_id
        from profiles
        where lower(email) = lower(new.email)
        limit 1;
    end if;
    return new;
end;
$$;

drop trigger if exists manual_debts_auto_link_user on manual_debts;
create trigger manual_debts_auto_link_user
    before insert or update on manual_debts
    for each row execute function auto_link_manual_debt_user_id();

-- 2. Aggiorna le righe esistenti che hanno user_id NULL
update manual_debts md
set user_id = p.id
from profiles p
where lower(md.email) = lower(p.email)
  and md.user_id is null;
