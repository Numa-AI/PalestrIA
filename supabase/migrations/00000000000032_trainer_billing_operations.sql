-- Transactional and auditable trainer billing operations.

alter table payments add column if not exists reversed_payment_id uuid
  references payments(id) on delete set null;
alter table profiles add column if not exists archived_at timestamptz;

create table if not exists admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text not null,
  target_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists admin_audit_log_org_created_idx
  on admin_audit_log(org_id, created_at desc);
alter table admin_audit_log enable row level security;
drop policy if exists admin_audit_log_admin_read on admin_audit_log;
create policy admin_audit_log_admin_read on admin_audit_log
  for select to authenticated using (is_org_admin(org_id));

alter table client_packages
  add constraint client_packages_sessions_valid
  check (total_sessions > 0 and remaining_sessions between 0 and total_sessions) not valid;
alter table client_packages
  add constraint client_packages_price_valid
  check (price is null or price >= 0) not valid;
alter table client_memberships
  add constraint client_memberships_period_valid
  check (period_end >= period_start) not valid;
alter table client_memberships
  add constraint client_memberships_quota_valid
  check (lessons_quota is null or
    (lessons_quota > 0 and lessons_used between 0 and lessons_quota)) not valid;
alter table client_memberships
  add constraint client_memberships_price_valid
  check (price is null or price >= 0) not valid;

drop function if exists admin_sell_package(uuid,text,integer,numeric,text,date);
create function admin_sell_package(
  p_user_id uuid,
  p_label text,
  p_sessions integer,
  p_price numeric,
  p_method text default 'contanti',
  p_expires date default null,
  p_idempotency_key text default null,
  p_note text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := current_org_id();
  v_pkg uuid;
  v_email text;
  v_currency text;
  v_key text := nullif(trim(coalesce(p_idempotency_key,'')),'');
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_sessions is null or p_sessions <= 0 or p_sessions > 10000 then raise exception 'invalid_sessions'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'invalid_price'; end if;
  if p_method not in ('contanti','contanti-report','carta','iban','stripe','gratuito') then raise exception 'invalid_method'; end if;
  if p_expires is not null and p_expires < current_date then raise exception 'invalid_expiry'; end if;
  if length(trim(coalesce(p_label,''))) > 120 or length(coalesce(p_note,'')) > 500 then raise exception 'invalid_text'; end if;

  select email into v_email from profiles
    where id=p_user_id and org_id=v_org and archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  select coalesce(currency,'EUR') into v_currency from organizations where id=v_org;

  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(v_org::text||'|package|'||v_key));
    select package_id into v_pkg from payments
      where org_id=v_org and idempotency_key=v_key and kind='package_purchase';
    if found and v_pkg is not null then return v_pkg; end if;
  end if;

  update client_packages set status='expired'
    where org_id=v_org and user_id=p_user_id and status='active'
      and expires_at is not null and expires_at < current_date;
  insert into client_packages(org_id,user_id,label,total_sessions,remaining_sessions,expires_at,price)
  values(v_org,p_user_id,nullif(trim(coalesce(p_label,'')),''),p_sessions,p_sessions,p_expires,p_price)
  returning id into v_pkg;
  insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
    package_id,note,created_by,idempotency_key)
  values(v_org,p_user_id,v_email,p_price,v_currency,p_method,'package_purchase',v_pkg,
    nullif(trim(coalesce(p_note,'')),''),auth.uid(),v_key);
  insert into client_billing_profiles(org_id,user_id,client_email,model_override)
  values(v_org,p_user_id,v_email,'package')
  on conflict(org_id,user_id) do update set
    client_email=excluded.client_email,model_override=excluded.model_override;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'package_sold','client_package',v_pkg::text,
    jsonb_build_object('client_user_id',p_user_id,'sessions',p_sessions,'amount',p_price,
      'method',p_method,'expires_at',p_expires));
  return v_pkg;
end;
$$;
revoke all on function admin_sell_package(uuid,text,integer,numeric,text,date,text,text) from public;
grant execute on function admin_sell_package(uuid,text,integer,numeric,text,date,text,text) to authenticated;

drop function if exists admin_record_membership_payment(uuid,text,numeric,date,date,integer,text);
create function admin_record_membership_payment(
  p_user_id uuid,
  p_label text,
  p_price numeric,
  p_period_start date,
  p_period_end date,
  p_lessons_quota integer default null,
  p_method text default 'contanti',
  p_auto_renew boolean default false,
  p_idempotency_key text default null,
  p_note text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := current_org_id();
  v_mem uuid;
  v_email text;
  v_currency text;
  v_key text := nullif(trim(coalesce(p_idempotency_key,'')),'');
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then raise exception 'invalid_period'; end if;
  if p_period_end > p_period_start + 730 then raise exception 'period_too_long'; end if;
  if p_lessons_quota is not null and (p_lessons_quota <= 0 or p_lessons_quota > 10000) then raise exception 'invalid_quota'; end if;
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'invalid_price'; end if;
  if p_method not in ('contanti','contanti-report','carta','iban','stripe','gratuito') then raise exception 'invalid_method'; end if;
  if length(trim(coalesce(p_label,''))) > 120 or length(coalesce(p_note,'')) > 500 then raise exception 'invalid_text'; end if;

  select email into v_email from profiles
    where id=p_user_id and org_id=v_org and archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  select coalesce(currency,'EUR') into v_currency from organizations where id=v_org;

  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(v_org::text||'|membership|'||v_key));
    select membership_id into v_mem from payments
      where org_id=v_org and idempotency_key=v_key and kind='membership';
    if found and v_mem is not null then return v_mem; end if;
  end if;

  update client_memberships set status='expired'
    where org_id=v_org and user_id=p_user_id and status='active' and period_end < current_date;
  insert into client_memberships(org_id,user_id,plan_label,period_start,period_end,
    lessons_quota,price,status,auto_renew)
  values(v_org,p_user_id,nullif(trim(coalesce(p_label,'')),''),p_period_start,p_period_end,
    p_lessons_quota,p_price,'active',p_auto_renew)
  returning id into v_mem;
  insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
    membership_id,period_start,period_end,note,created_by,idempotency_key)
  values(v_org,p_user_id,v_email,p_price,v_currency,p_method,'membership',v_mem,
    p_period_start,p_period_end,nullif(trim(coalesce(p_note,'')),''),auth.uid(),v_key);
  insert into client_billing_profiles(org_id,user_id,client_email,model_override)
  values(v_org,p_user_id,v_email,'monthly')
  on conflict(org_id,user_id) do update set
    client_email=excluded.client_email,model_override=excluded.model_override;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'membership_sold','client_membership',v_mem::text,
    jsonb_build_object('client_user_id',p_user_id,'amount',p_price,'method',p_method,
      'period_start',p_period_start,'period_end',p_period_end,'quota',p_lessons_quota));
  return v_mem;
end;
$$;
revoke all on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text) from public;
grant execute on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text) to authenticated;
