-- Sincronizza l'email applicativa solo quando GoTrue ha realmente confermato
-- il cambio in auth.users. Il client non può modificare profiles.email.
create or replace function public.sync_confirmed_auth_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is not null and new.email is distinct from old.email then
    update public.profiles
       set email = lower(trim(new.email))
     where id = new.id;

    update public.bookings
       set email = lower(trim(new.email))
     where user_id = new.id;
  end if;
  return new;
end;
$$;

revoke all on function public.sync_confirmed_auth_email() from public, anon, authenticated;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row
  when (new.email is distinct from old.email)
  execute function public.sync_confirmed_auth_email();

-- La vecchia RPC non deve più dichiarare successo quando l'utente non esiste.
-- I nuovi inviti usano invite-org-member; questa RPC resta compatibile per
-- associare utenti già registrati.
create or replace function public.invite_org_member(p_email text, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org uuid := current_org_id();
  v_user uuid;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_role not in ('admin','staff') then raise exception 'invalid_role'; end if;

  select id into v_user
    from auth.users
   where lower(email) = lower(trim(p_email));
  if v_user is null then raise exception 'user_not_found'; end if;

  insert into org_members (org_id, user_id, role, status, invited_email)
  values (v_org, v_user, p_role, 'active', lower(trim(p_email)))
  on conflict (org_id, user_id) do update
    set role = excluded.role,
        status = 'active',
        invited_email = excluded.invited_email;
end;
$$;
revoke all on function public.invite_org_member(text, text) from public, anon;
grant execute on function public.invite_org_member(text, text) to authenticated;
-- Staff: accesso operativo in sola lettura, senza privilegi amministrativi.
create or replace function public.is_org_staff(p_org_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from org_members m
     where m.user_id = auth.uid()
       and m.status = 'active'
       and m.role = 'staff'
       and m.org_id = coalesce(p_org_id, current_org_id())
  )
$$;
revoke all on function public.is_org_staff(uuid) from public, anon;
grant execute on function public.is_org_staff(uuid) to authenticated;

drop policy if exists profiles_staff_read on public.profiles;
create policy profiles_staff_read on public.profiles
  for select to authenticated
  using (org_id = current_org_id() and is_org_staff(org_id));

drop policy if exists bookings_staff_read on public.bookings;
create policy bookings_staff_read on public.bookings
  for select to authenticated
  using (org_id = current_org_id() and is_org_staff(org_id));