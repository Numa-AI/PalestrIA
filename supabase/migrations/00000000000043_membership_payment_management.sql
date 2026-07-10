-- Pagamenti abbonamento espliciti per periodo e panoramica rinnovi.

alter table client_memberships
  add column if not exists payment_id uuid references payments(id) on delete set null,
  add column if not exists payment_method text,
  add column if not exists paid_at timestamptz;

update client_memberships m set payment_id=p.id,payment_method=p.method,paid_at=p.created_at
from payments p where p.membership_id=m.id and p.org_id=m.org_id
  and m.payment_id is null and p.kind='membership';

create or replace function admin_record_membership_payment(
  p_user_id uuid,p_label text,p_price numeric,p_period_start date,p_period_end date,
  p_lessons_quota integer default null,p_method text default 'contanti',
  p_auto_renew boolean default false,p_idempotency_key text default null,
  p_note text default null,p_billing_period text default 'monthly'
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id(); v_mem uuid; v_payment uuid; v_email text;
  v_currency text; v_key text; v_column text; v_detail text;
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
  v_key:=coalesce(nullif(trim(coalesce(p_idempotency_key,'')),''),'membership:'||gen_random_uuid()::text);
  perform pg_advisory_xact_lock(hashtext(v_org::text||'|membership|'||v_key));
  select membership_id into v_mem from payments
    where org_id=v_org and idempotency_key=v_key and kind='membership';
  if found and v_mem is not null then return v_mem; end if;

  update client_memberships set status='expired'
    where org_id=v_org and user_id=p_user_id and status='active' and period_end<p_period_start;
  v_mem:=gen_random_uuid();
  insert into client_memberships(id,org_id,user_id,plan_label,billing_period,
    period_start,period_end,lessons_quota,lessons_used,status,auto_renew,price,created_at,
    payment_method,paid_at)
  values(v_mem,v_org,p_user_id,coalesce(nullif(trim(coalesce(p_label,'')),''),'Abbonamento'),
    p_billing_period,p_period_start,p_period_end,p_lessons_quota,0,'active',
    coalesce(p_auto_renew,false),p_price,now(),p_method,now());
  insert into payments(id,org_id,created_at,client_user_id,client_email,amount,currency,
    method,kind,membership_id,period_start,period_end,note,created_by,idempotency_key)
  values(gen_random_uuid(),v_org,now(),p_user_id,v_email,p_price,v_currency,p_method,
    'membership',v_mem,p_period_start,p_period_end,nullif(trim(coalesce(p_note,'')),''),
    auth.uid(),v_key) returning id into v_payment;
  update client_memberships set payment_id=v_payment where id=v_mem and org_id=v_org;
  insert into client_billing_profiles(org_id,user_id,client_email,model_override,membership_period_override)
  values(v_org,p_user_id,v_email,'monthly',p_billing_period)
  on conflict(org_id,user_id) do update set client_email=excluded.client_email,
    model_override=excluded.model_override,membership_period_override=excluded.membership_period_override;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'membership_payment_recorded','client_membership',v_mem::text,
    jsonb_build_object('payment_id',v_payment,'client_user_id',p_user_id,
      'billing_period',p_billing_period,'amount',p_price,'method',p_method,
      'period_start',p_period_start,'period_end',p_period_end,'quota',p_lessons_quota));
  return v_mem;
exception when not_null_violation then
  get stacked diagnostics v_column=column_name,v_detail=message_text;
  raise exception 'membership_payment_missing_required_field:%:%',coalesce(v_column,'unknown'),v_detail
    using errcode='P0001';
end;
$$;
revoke all on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text,text) from public,anon;
grant execute on function admin_record_membership_payment(uuid,text,numeric,date,date,integer,text,boolean,text,text,text) to authenticated;

create or replace function get_membership_payment_overview()
returns table(
  user_id uuid,name text,email text,whatsapp text,membership_id uuid,
  plan_label text,billing_period text,period_start date,period_end date,
  membership_status text,auto_renew boolean,amount numeric,payment_method text,
  paid_at timestamptz,needs_renewal boolean
)
language plpgsql security definer set search_path=public as $$
declare v_org uuid:=current_org_id();
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  update client_memberships set status='expired'
    where org_id=v_org and status='active' and period_end<current_date;
  return query
  select p.id,p.name,p.email,p.whatsapp,m.id,m.plan_label,m.billing_period,
    m.period_start,m.period_end,coalesce(m.status,'missing'),coalesce(m.auto_renew,false),
    coalesce(pay.amount,m.price,case coalesce(m.billing_period,bs.default_membership_period,'monthly')
      when 'quarterly' then bs.membership_quarterly_price
      when 'annual' then bs.membership_annual_price else bs.membership_monthly_price end),
    coalesce(pay.method,m.payment_method),coalesce(pay.created_at,m.paid_at),
    (m.id is null or m.status<>'active' or m.period_end<current_date)
  from profiles p join billing_settings bs on bs.org_id=p.org_id
  left join client_billing_profiles cbp on cbp.org_id=p.org_id and cbp.user_id=p.id
  left join lateral (
    select cm.* from client_memberships cm where cm.org_id=p.org_id and cm.user_id=p.id
    order by cm.period_end desc,cm.created_at desc limit 1
  ) m on true
  left join payments pay on pay.id=m.payment_id
  where p.org_id=v_org and p.archived_at is null
    and coalesce(cbp.model_override,bs.default_model,'pay_per_session')='monthly'
  order by (m.id is null or m.status<>'active' or m.period_end<current_date) desc,
    m.period_end nulls first,p.name;
end;
$$;
revoke all on function get_membership_payment_overview() from public,anon;
grant execute on function get_membership_payment_overview() to authenticated;
