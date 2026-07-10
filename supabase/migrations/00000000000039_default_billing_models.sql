-- Modelli di pagamento predefiniti: listini separati, periodicita membership,
-- saldo a lezione congelato e cambio modello atomico/auditabile.

alter table billing_settings
  add column if not exists default_membership_period text not null default 'monthly',
  add column if not exists package_label text not null default 'Pacchetto 10 ingressi',
  add column if not exists package_sessions integer not null default 10,
  add column if not exists package_price numeric(10,2) not null default 0,
  add column if not exists membership_monthly_price numeric(10,2) not null default 0,
  add column if not exists membership_quarterly_price numeric(10,2) not null default 0,
  add column if not exists membership_annual_price numeric(10,2) not null default 0,
  add column if not exists model_changed_at timestamptz not null default now();

alter table billing_settings drop constraint if exists billing_settings_default_membership_period_check;
alter table billing_settings add constraint billing_settings_default_membership_period_check
  check (default_membership_period in ('monthly','quarterly','annual'));
alter table billing_settings drop constraint if exists billing_settings_package_sessions_check;
alter table billing_settings add constraint billing_settings_package_sessions_check
  check (package_sessions > 0 and package_sessions <= 10000);
alter table billing_settings drop constraint if exists billing_settings_catalog_prices_check;
alter table billing_settings add constraint billing_settings_catalog_prices_check check (
  package_price >= 0 and membership_monthly_price >= 0
  and membership_quarterly_price >= 0 and membership_annual_price >= 0
);

alter table client_billing_profiles
  add column if not exists membership_period_override text;
alter table client_billing_profiles drop constraint if exists client_billing_profiles_membership_period_override_check;
alter table client_billing_profiles add constraint client_billing_profiles_membership_period_override_check
  check (membership_period_override is null or membership_period_override in ('monthly','quarterly','annual'));

alter table client_memberships
  add column if not exists billing_period text not null default 'monthly';
alter table client_memberships drop constraint if exists client_memberships_billing_period_check;
alter table client_memberships add constraint client_memberships_billing_period_check
  check (billing_period in ('monthly','quarterly','annual'));

alter table bookings
  add column if not exists billing_voided_at timestamptz,
  add column if not exists billing_void_reason text;

-- Il prezzo di una lezione a entrata viene congelato al momento della
-- prenotazione: i cambi futuri del listino non riscrivono il passato.
create or replace function apply_client_booking_price()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_model text;
  v_price numeric;
begin
  if new.user_id is null then return new; end if;
  select coalesce(cbp.model_override,bs.default_model,'pay_per_session'),cbp.custom_price
    into v_model,v_price
    from billing_settings bs
    left join client_billing_profiles cbp
      on cbp.org_id=bs.org_id and cbp.user_id=new.user_id
    where bs.org_id=new.org_id;
  if coalesce(v_model,'pay_per_session')='pay_per_session' then
    new.custom_price:=coalesce(new.custom_price,v_price,get_org_price(new.org_id,new.slot_type),0);
  end if;
  return new;
end;
$$;
revoke all on function apply_client_booking_price() from public,anon,authenticated;

drop trigger if exists apply_client_booking_price_before_insert on bookings;
create trigger apply_client_booking_price_before_insert
  before insert on bookings for each row execute function apply_client_booking_price();

update bookings b set custom_price=get_org_price(b.org_id,b.slot_type)
where b.custom_price is null and not b.paid and b.billing_voided_at is null
  and b.status in ('confirmed','cancellation_requested');

-- Una posizione annullata dal cambio modello non puo essere incassata per errore.
create or replace function guard_voided_booking_payment()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.billing_voided_at is not null and not old.paid and new.paid then
    raise exception 'billing_obligation_voided';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_voided_booking_payment_before_update on bookings;
create trigger guard_voided_booking_payment_before_update
  before update of paid on bookings for each row execute function guard_voided_booking_payment();

-- Impedisce alle vecchie versioni dei client di cambiare modello con un semplice
-- UPDATE, saltando le tre conferme e l'annullamento atomico degli stati attivi.
create or replace function guard_default_billing_model_transition()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.default_model is distinct from new.default_model
     and current_user not in ('postgres','service_role') then
    raise exception 'use_admin_save_default_billing_model';
  end if;
  return new;
end;
$$;
drop trigger if exists guard_default_billing_model_transition_before_update on billing_settings;
create trigger guard_default_billing_model_transition_before_update
  before update of default_model on billing_settings
  for each row execute function guard_default_billing_model_transition();

create or replace function get_billing_model_change_impact(p_model text)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id();
  v_current text;
  v_target text;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_model not in ('pay_per_session','package','monthly','quarterly','annual','free') then
    raise exception 'invalid_model';
  end if;
  v_target:=case when p_model in ('monthly','quarterly','annual') then 'monthly' else p_model end;
  select default_model into v_current from billing_settings where org_id=v_org;
  v_current:=coalesce(v_current,'pay_per_session');
  return jsonb_build_object(
    'current_model',v_current,
    'target_model',v_target,
    'model_changed',v_current<>v_target,
    'open_session_balances',(select count(*) from bookings where org_id=v_org
      and billing_voided_at is null and status in ('confirmed','cancellation_requested')),
    'active_packages',(select count(*) from client_packages where org_id=v_org and status='active'),
    'active_memberships',(select count(*) from client_memberships where org_id=v_org and status='active'),
    'client_overrides',(select count(*) from client_billing_profiles where org_id=v_org
      and model_override is not null)
  );
end;
$$;
revoke all on function get_billing_model_change_impact(text) from public,anon;
grant execute on function get_billing_model_change_impact(text) to authenticated;

create or replace function admin_save_default_billing_model(
  p_model text,
  p_block_unpaid_threshold numeric,
  p_block_if_membership_expired boolean,
  p_block_if_no_package boolean,
  p_grace_days integer,
  p_package_auto_decrement boolean,
  p_package_label text,
  p_package_sessions integer,
  p_package_price numeric,
  p_monthly_price numeric,
  p_quarterly_price numeric,
  p_annual_price numeric,
  p_slot_prices jsonb default '{}'::jsonb,
  p_expected_current_model text default null,
  p_confirm_1 boolean default false,
  p_confirm_2 boolean default false,
  p_confirm_3 boolean default false
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id();
  v_base text;
  v_period text;
  v_current text;
  v_changed boolean;
  v_open integer:=0;
  v_packages integer:=0;
  v_memberships integer:=0;
  v_overrides integer:=0;
  v_item record;
  v_price numeric;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_model not in ('pay_per_session','package','monthly','quarterly','annual','free') then raise exception 'invalid_model'; end if;
  if p_block_unpaid_threshold is null or p_block_unpaid_threshold<0 or p_block_unpaid_threshold>1000000 then raise exception 'invalid_threshold'; end if;
  if p_grace_days is null or p_grace_days<0 or p_grace_days>365 then raise exception 'invalid_grace_days'; end if;
  if p_package_sessions is null or p_package_sessions<1 or p_package_sessions>10000 then raise exception 'invalid_package_sessions'; end if;
  if length(trim(coalesce(p_package_label,'')))<1 or length(trim(p_package_label))>120 then raise exception 'invalid_package_label'; end if;
  if p_package_price is null or p_monthly_price is null or p_quarterly_price is null or p_annual_price is null
     or least(p_package_price,p_monthly_price,p_quarterly_price,p_annual_price)<0
     or greatest(p_package_price,p_monthly_price,p_quarterly_price,p_annual_price)>1000000 then
    raise exception 'invalid_catalog_price';
  end if;

  v_base:=case when p_model in ('monthly','quarterly','annual') then 'monthly' else p_model end;
  v_period:=case when p_model in ('monthly','quarterly','annual') then p_model else 'monthly' end;
  insert into billing_settings(org_id) values(v_org) on conflict(org_id) do nothing;
  select default_model into v_current from billing_settings where org_id=v_org for update;
  v_current:=coalesce(v_current,'pay_per_session');
  if p_expected_current_model is not null and p_expected_current_model<>v_current then raise exception 'billing_model_changed_elsewhere'; end if;
  v_changed:=v_current<>v_base;
  if v_changed and not (p_confirm_1 and p_confirm_2 and p_confirm_3) then raise exception 'billing_change_confirmation_required'; end if;

  if v_changed then
    update bookings set billing_voided_at=now(),billing_void_reason='default_model_changed'
      where org_id=v_org and billing_voided_at is null
        and status in ('confirmed','cancellation_requested');
    get diagnostics v_open=row_count;
    update client_packages set status='cancelled' where org_id=v_org and status='active';
    get diagnostics v_packages=row_count;
    update client_memberships set status='cancelled',auto_renew=false where org_id=v_org and status='active';
    get diagnostics v_memberships=row_count;
    update client_billing_profiles set model_override=null,custom_price=null,
      membership_period_override=null where org_id=v_org and model_override is not null;
    get diagnostics v_overrides=row_count;
  end if;

  update billing_settings set
    default_model=v_base,default_membership_period=v_period,
    block_unpaid_threshold=p_block_unpaid_threshold,
    block_if_membership_expired=p_block_if_membership_expired,
    block_if_no_package=p_block_if_no_package,grace_days=p_grace_days,
    package_auto_decrement=p_package_auto_decrement,
    package_label=trim(p_package_label),package_sessions=p_package_sessions,
    package_price=p_package_price,membership_monthly_price=p_monthly_price,
    membership_quarterly_price=p_quarterly_price,membership_annual_price=p_annual_price,
    model_changed_at=case when v_changed then now() else model_changed_at end,updated_at=now()
    where org_id=v_org;

  for v_item in select key,value from jsonb_each(coalesce(p_slot_prices,'{}'::jsonb)) loop
    begin v_price:=(v_item.value#>>'{}')::numeric;
    exception when invalid_text_representation then raise exception 'invalid_slot_price'; end;
    if v_price<0 or v_price>1000000 then raise exception 'invalid_slot_price'; end if;
    update slot_types set default_price=v_price where org_id=v_org and key=v_item.key;
    if not found then raise exception 'slot_type_not_found:%',v_item.key; end if;
  end loop;
  insert into org_settings(org_id,key,value,updated_at,updated_by)
    values(v_org,'billing_client.prices',coalesce(p_slot_prices,'{}'::jsonb),now(),auth.uid())
    on conflict(org_id,key) do update set value=excluded.value,updated_at=excluded.updated_at,updated_by=excluded.updated_by;

  if v_changed then
    insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
    values(v_org,auth.uid(),'default_billing_model_changed','billing_settings',v_org::text,
      jsonb_build_object('from',v_current,'to',v_base,'voided_session_balances',v_open,
        'cancelled_packages',v_packages,'cancelled_memberships',v_memberships,
        'cleared_client_overrides',v_overrides,'historical_payments_preserved',true));
  end if;
  return jsonb_build_object('success',true,'model_changed',v_changed,'current_model',v_base,
    'voided_session_balances',v_open,'cancelled_packages',v_packages,
    'cancelled_memberships',v_memberships,'cleared_client_overrides',v_overrides);
end;
$$;
revoke all on function admin_save_default_billing_model(text,numeric,boolean,boolean,integer,boolean,text,integer,numeric,numeric,numeric,numeric,jsonb,text,boolean,boolean,boolean) from public,anon;
grant execute on function admin_save_default_billing_model(text,numeric,boolean,boolean,integer,boolean,text,integer,numeric,numeric,numeric,numeric,jsonb,text,boolean,boolean,boolean) to authenticated;

-- Compatibilita: quarterly/annual in input vengono normalizzati nell'unico
-- modello membership (`monthly`) e salvati soltanto come durata.
create or replace function admin_set_client_billing_model(
  p_user_id uuid,p_model text,p_custom_price numeric default null,p_notes text default null
) returns void
language plpgsql security definer set search_path=public as $$
declare v_org uuid:=current_org_id(); v_email text; v_base text; v_period text;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_model not in ('pay_per_session','monthly','quarterly','annual','package','free') then raise exception 'invalid_model'; end if;
  if p_custom_price is not null and (p_custom_price<0 or p_custom_price>1000000) then raise exception 'invalid_price'; end if;
  if length(coalesce(p_notes,''))>500 then raise exception 'invalid_notes'; end if;
  select email into v_email from profiles where id=p_user_id and org_id=v_org and archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  v_base:=case when p_model in ('monthly','quarterly','annual') then 'monthly' else p_model end;
  v_period:=case when p_model in ('monthly','quarterly','annual') then p_model else null end;
  insert into client_billing_profiles(org_id,user_id,client_email,model_override,
    membership_period_override,custom_price,notes)
  values(v_org,p_user_id,v_email,v_base,v_period,
    case when v_base='pay_per_session' then p_custom_price else null end,
    nullif(trim(coalesce(p_notes,'')),''))
  on conflict(org_id,user_id) do update set client_email=excluded.client_email,
    model_override=excluded.model_override,membership_period_override=excluded.membership_period_override,
    custom_price=excluded.custom_price,notes=excluded.notes;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'billing_model_changed','profile',p_user_id::text,
    jsonb_build_object('model',p_model,'custom_price',p_custom_price));
end;
$$;
revoke all on function admin_set_client_billing_model(uuid,text,numeric,text) from public;
grant execute on function admin_set_client_billing_model(uuid,text,numeric,text) to authenticated;

drop function if exists admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text);
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
  p_note text default null,
  p_billing_period text default 'monthly'
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id(); v_mem uuid; v_email text; v_currency text;
  v_key text:=nullif(trim(coalesce(p_idempotency_key,'')),'');
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_billing_period not in ('monthly','quarterly','annual') then raise exception 'invalid_billing_period'; end if;
  if p_period_start is null or p_period_end is null or p_period_end<p_period_start then raise exception 'invalid_period'; end if;
  if p_period_end>p_period_start+730 then raise exception 'period_too_long'; end if;
  if p_lessons_quota is not null and (p_lessons_quota<=0 or p_lessons_quota>10000) then raise exception 'invalid_quota'; end if;
  if p_price is null or p_price<0 or p_price>1000000 then raise exception 'invalid_price'; end if;
  if p_method not in ('contanti','contanti-report','carta','iban','stripe','gratuito') then raise exception 'invalid_method'; end if;
  if length(trim(coalesce(p_label,'')))>120 or length(coalesce(p_note,''))>500 then raise exception 'invalid_text'; end if;
  select email into v_email from profiles where id=p_user_id and org_id=v_org and archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  select coalesce(currency,'EUR') into v_currency from organizations where id=v_org;
  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(v_org::text||'|membership|'||v_key));
    select membership_id into v_mem from payments where org_id=v_org and idempotency_key=v_key and kind='membership';
    if found and v_mem is not null then return v_mem; end if;
  end if;
  update client_memberships set status='expired' where org_id=v_org and user_id=p_user_id
    and status='active' and period_end<current_date;
  insert into client_memberships(org_id,user_id,plan_label,billing_period,period_start,period_end,
    lessons_quota,price,status,auto_renew)
  values(v_org,p_user_id,nullif(trim(coalesce(p_label,'')),''),p_billing_period,p_period_start,
    p_period_end,p_lessons_quota,p_price,'active',p_auto_renew) returning id into v_mem;
  insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
    membership_id,period_start,period_end,note,created_by,idempotency_key)
  values(v_org,p_user_id,v_email,p_price,v_currency,p_method,'membership',v_mem,p_period_start,
    p_period_end,nullif(trim(coalesce(p_note,'')),''),auth.uid(),v_key);
  insert into client_billing_profiles(org_id,user_id,client_email,model_override,membership_period_override)
  values(v_org,p_user_id,v_email,'monthly',p_billing_period)
  on conflict(org_id,user_id) do update set client_email=excluded.client_email,
    model_override=excluded.model_override,membership_period_override=excluded.membership_period_override;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'membership_sold','client_membership',v_mem::text,
    jsonb_build_object('client_user_id',p_user_id,'billing_period',p_billing_period,
      'amount',p_price,'method',p_method,'period_start',p_period_start,'period_end',p_period_end,
      'quota',p_lessons_quota));
  return v_mem;
end;
$$;
revoke all on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text,text) from public;
grant execute on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text,text) to authenticated;

-- Summary unica: credito a entrata = scaduto + lezioni future, esclude le
-- posizioni annullate dal cambio modello; ledger storico sempre invariato.
create or replace function get_client_financial_summary(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_org uuid:=current_org_id(); v_result jsonb; v_model text; v_due numeric:=0; v_future numeric:=0;
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  if not exists(select 1 from profiles where id=p_user_id and org_id=v_org) then raise exception 'client_not_found'; end if;
  select coalesce(cbp.model_override,bs.default_model,'pay_per_session')
    into v_model from billing_settings bs left join client_billing_profiles cbp
      on cbp.org_id=bs.org_id and cbp.user_id=p_user_id where bs.org_id=v_org;
  v_model:=coalesce(v_model,'pay_per_session');
  if v_model='pay_per_session' then
    select
      coalesce(sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type))) filter(where b.date<=current_date),0),
      coalesce(sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type))) filter(where b.date>current_date),0)
      into v_due,v_future from bookings b where b.org_id=v_org and b.user_id=p_user_id
        and not b.paid and b.billing_voided_at is null
        and b.status in ('confirmed','cancellation_requested');
  end if;
  select jsonb_build_object(
    'billing_profile',coalesce((select to_jsonb(x) from (select v_model model,
      coalesce(cbp.membership_period_override,bs.default_membership_period,'monthly') membership_period,
      cbp.custom_price,cbp.notes
      from billing_settings bs left join client_billing_profiles cbp on cbp.org_id=bs.org_id
        and cbp.user_id=p_user_id where bs.org_id=v_org) x),
      jsonb_build_object('model',v_model,'custom_price',null,'notes',null)),
    'packages',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,label,total_sessions,remaining_sessions,expires_at,status,price,created_at
      from client_packages where org_id=v_org and user_id=p_user_id order by created_at desc limit 20) x),'[]'::jsonb),
    'memberships',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,plan_label,billing_period,period_start,period_end,lessons_quota,lessons_used,status,auto_renew,price,created_at
      from client_memberships where org_id=v_org and user_id=p_user_id order by created_at desc limit 20) x),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,amount,currency,method,kind,note,period_start,period_end,created_at,reversed_payment_id
      from payments where org_id=v_org and client_user_id=p_user_id order by created_at desc limit 50) x),'[]'::jsonb),
    'totals',jsonb_build_object(
      'collected',coalesce((select sum(amount) from payments where org_id=v_org and client_user_id=p_user_id),0),
      'unpaid',v_due,'unpaid_count',case when v_model='pay_per_session' then
        (select count(*) from bookings b where b.org_id=v_org and b.user_id=p_user_id
          and not b.paid and b.billing_voided_at is null and b.date<=current_date
          and b.status in ('confirmed','cancellation_requested')) else 0 end,
      'scheduled',v_future,'credit',v_due+v_future,
      'credit_count',case when v_model='pay_per_session' then
        (select count(*) from bookings b where b.org_id=v_org and b.user_id=p_user_id
          and not b.paid and b.billing_voided_at is null
          and b.status in ('confirmed','cancellation_requested')) else 0 end),
    'health',jsonb_build_object(
      'archived',(select archived_at is not null from profiles where id=p_user_id),
      'medical_cert_expired',coalesce((select medical_cert_expiry<current_date from profiles where id=p_user_id),false),
      'insurance_expired',coalesce((select insurance_expiry<current_date from profiles where id=p_user_id),false),
      'active_package',exists(select 1 from client_packages where org_id=v_org and user_id=p_user_id
        and status='active' and remaining_sessions>0 and (expires_at is null or expires_at>=current_date)),
      'active_membership',exists(select 1 from client_memberships where org_id=v_org and user_id=p_user_id
        and status='active' and period_start<=current_date and period_end>=current_date-make_interval(days=>coalesce(
          (select grace_days from billing_settings where org_id=v_org),0))
        and (lessons_quota is null or lessons_used<lessons_quota)),
      'billing_coverage_missing',case when v_model='package' then not exists(select 1 from client_packages
        where org_id=v_org and user_id=p_user_id and status='active' and remaining_sessions>0
          and (expires_at is null or expires_at>=current_date)) when v_model in ('monthly','quarterly','annual')
        then not exists(select 1 from client_memberships where org_id=v_org and user_id=p_user_id
          and status='active' and period_start<=current_date
          and period_end>=current_date-make_interval(days=>coalesce(
            (select grace_days from billing_settings where org_id=v_org),0))
          and (lessons_quota is null or lessons_used<lessons_quota)) else false end,
      'unpaid_over_threshold',v_model='pay_per_session' and v_due>
        coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)
        and coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)>0)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function get_client_financial_summary(uuid) from public,anon;
grant execute on function get_client_financial_summary(uuid) to authenticated;
