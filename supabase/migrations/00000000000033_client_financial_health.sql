-- Client lifecycle, billing model, adjustments and financial health summary.

create or replace function admin_set_client_billing_model(
  p_user_id uuid,
  p_model text,
  p_custom_price numeric default null,
  p_notes text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_email text;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_model not in ('pay_per_session','monthly','package','free') then raise exception 'invalid_model'; end if;
  if p_custom_price is not null and (p_custom_price < 0 or p_custom_price > 1000000) then raise exception 'invalid_price'; end if;
  if length(coalesce(p_notes,'')) > 500 then raise exception 'invalid_notes'; end if;
  select email into v_email from profiles where id=p_user_id and org_id=v_org and archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  insert into client_billing_profiles(org_id,user_id,client_email,model_override,custom_price,notes)
  values(v_org,p_user_id,v_email,p_model,p_custom_price,nullif(trim(coalesce(p_notes,'')),''))
  on conflict(org_id,user_id) do update set
    client_email=excluded.client_email,model_override=excluded.model_override,
    custom_price=excluded.custom_price,notes=excluded.notes;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'billing_model_changed','profile',p_user_id::text,
    jsonb_build_object('model',p_model,'custom_price',p_custom_price));
end;
$$;
revoke all on function admin_set_client_billing_model(uuid,text,numeric,text) from public;
grant execute on function admin_set_client_billing_model(uuid,text,numeric,text) to authenticated;

create or replace function admin_record_payment_adjustment(
  p_user_id uuid,
  p_amount numeric,
  p_method text,
  p_note text,
  p_reversed_payment_id uuid default null,
  p_idempotency_key text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := current_org_id(); v_email text; v_currency text;
  v_key text := nullif(trim(coalesce(p_idempotency_key,'')),'');
  v_id uuid; v_original payments%rowtype; v_previous numeric := 0;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_amount is null or p_amount=0 or abs(p_amount)>1000000 then raise exception 'invalid_amount'; end if;
  if p_method not in ('contanti','contanti-report','carta','iban','stripe','gratuito') then raise exception 'invalid_method'; end if;
  if trim(coalesce(p_note,''))='' or length(p_note)>500 then raise exception 'note_required'; end if;
  select email into v_email from profiles where id=p_user_id and org_id=v_org;
  if not found then raise exception 'client_not_found'; end if;
  select coalesce(currency,'EUR') into v_currency from organizations where id=v_org;
  if v_key is not null then
    perform pg_advisory_xact_lock(hashtext(v_org::text||'|adjustment|'||v_key));
    select id into v_id from payments where org_id=v_org and idempotency_key=v_key;
    if found then return v_id; end if;
  end if;
  if p_reversed_payment_id is not null then
    select * into v_original from payments
      where id=p_reversed_payment_id and org_id=v_org and client_user_id=p_user_id for update;
    if not found then raise exception 'payment_not_found'; end if;
    if p_amount >= 0 then raise exception 'refund_must_be_negative'; end if;
    select coalesce(sum(amount),0) into v_previous from payments
      where org_id=v_org and reversed_payment_id=p_reversed_payment_id;
    if v_original.amount + v_previous + p_amount < 0 then raise exception 'refund_exceeds_payment'; end if;
  end if;
  insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
    note,created_by,idempotency_key,reversed_payment_id)
  values(v_org,p_user_id,v_email,p_amount,v_currency,p_method,'adjustment',trim(p_note),
    auth.uid(),v_key,p_reversed_payment_id)
  returning id into v_id;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),case when p_amount<0 then 'payment_refund' else 'payment_adjustment' end,
    'payment',v_id::text,jsonb_build_object('client_user_id',p_user_id,'amount',p_amount,
      'method',p_method,'reversed_payment_id',p_reversed_payment_id));
  return v_id;
end;
$$;
revoke all on function admin_record_payment_adjustment(uuid,numeric,text,text,uuid,text) from public;
grant execute on function admin_record_payment_adjustment(uuid,numeric,text,text,uuid,text) to authenticated;

create or replace function admin_cancel_client_package(p_package_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_user uuid;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  update client_packages set status='cancelled'
    where id=p_package_id and org_id=v_org and status<>'cancelled'
    returning user_id into v_user;
  if not found then raise exception 'package_not_found_or_cancelled'; end if;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'package_cancelled','client_package',p_package_id::text,
    jsonb_build_object('client_user_id',v_user));
end;
$$;
revoke all on function admin_cancel_client_package(uuid) from public;
grant execute on function admin_cancel_client_package(uuid) to authenticated;

create or replace function admin_cancel_client_membership(p_membership_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_user uuid;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  update client_memberships set status='cancelled',auto_renew=false
    where id=p_membership_id and org_id=v_org and status<>'cancelled'
    returning user_id into v_user;
  if not found then raise exception 'membership_not_found_or_cancelled'; end if;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'membership_cancelled','client_membership',p_membership_id::text,
    jsonb_build_object('client_user_id',v_user));
end;
$$;
revoke all on function admin_cancel_client_membership(uuid) from public;
grant execute on function admin_cancel_client_membership(uuid) to authenticated;

create or replace function admin_update_client_details(
  p_user_id uuid,
  p_name text,
  p_whatsapp text default null,
  p_medical_cert_expiry date default null,
  p_insurance_expiry date default null,
  p_codice_fiscale text default null,
  p_indirizzo_via text default null,
  p_indirizzo_cap text default null,
  p_indirizzo_paese text default null,
  p_documento_firmato boolean default false
) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_phone text := nullif(trim(coalesce(p_whatsapp,'')),'');
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if trim(coalesce(p_name,''))='' or length(trim(p_name))>120 then raise exception 'invalid_name'; end if;
  if v_phone is not null and length(v_phone)>30 then raise exception 'invalid_phone'; end if;
  if length(coalesce(p_codice_fiscale,''))>32 or length(coalesce(p_indirizzo_via,''))>180
     or length(coalesce(p_indirizzo_cap,''))>12 or length(coalesce(p_indirizzo_paese,''))>100 then
    raise exception 'invalid_profile_fields';
  end if;
  if v_phone is not null and exists(select 1 from profiles where org_id=v_org and id<>p_user_id and whatsapp=v_phone) then
    raise exception 'phone_already_used';
  end if;
  update profiles set name=trim(p_name),whatsapp=v_phone,
    medical_cert_expiry=p_medical_cert_expiry,insurance_expiry=p_insurance_expiry,
    codice_fiscale=nullif(upper(trim(coalesce(p_codice_fiscale,''))),''),
    indirizzo_via=nullif(trim(coalesce(p_indirizzo_via,'')),''),
    indirizzo_cap=nullif(trim(coalesce(p_indirizzo_cap,'')),''),
    indirizzo_paese=nullif(trim(coalesce(p_indirizzo_paese,'')),''),
    documento_firmato=p_documento_firmato
    where id=p_user_id and org_id=v_org;
  if not found then raise exception 'client_not_found'; end if;
  update bookings set name=trim(p_name),whatsapp=v_phone
    where org_id=v_org and user_id=p_user_id;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'client_updated','profile',p_user_id::text,'{}');
end;
$$;
revoke all on function admin_update_client_details(uuid,text,text,date,date,text,text,text,text,boolean) from public;
grant execute on function admin_update_client_details(uuid,text,text,date,date,text,text,text,text,boolean) to authenticated;

create or replace function admin_set_client_archived(p_user_id uuid,p_archived boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id();
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  update profiles set archived_at=case when p_archived then now() else null end
    where id=p_user_id and org_id=v_org;
  if not found then raise exception 'client_not_found'; end if;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),case when p_archived then 'client_archived' else 'client_restored' end,
    'profile',p_user_id::text,'{}');
end;
$$;
revoke all on function admin_set_client_archived(uuid,boolean) from public;
grant execute on function admin_set_client_archived(uuid,boolean) to authenticated;

create or replace function admin_reset_client_data(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_org uuid := current_org_id(); v_book int; v_mem int; v_pkg int; v_bp int; v_notif int;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if not exists(select 1 from profiles where id=p_user_id and org_id=v_org) then raise exception 'client_not_found'; end if;
  delete from bookings where org_id=v_org and user_id=p_user_id; get diagnostics v_book=row_count;
  delete from client_memberships where org_id=v_org and user_id=p_user_id; get diagnostics v_mem=row_count;
  delete from client_packages where org_id=v_org and user_id=p_user_id; get diagnostics v_pkg=row_count;
  delete from client_billing_profiles where org_id=v_org and user_id=p_user_id; get diagnostics v_bp=row_count;
  delete from client_notifications where org_id=v_org and user_id=p_user_id; get diagnostics v_notif=row_count;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'client_operational_data_reset','profile',p_user_id::text,
    jsonb_build_object('bookings',v_book,'memberships',v_mem,'packages',v_pkg,
      'billing_profiles',v_bp,'notifications',v_notif));
  return jsonb_build_object('success',true,'bookings_deleted',v_book,'memberships_deleted',v_mem,
    'packages_deleted',v_pkg,'billing_profiles_deleted',v_bp,'notifications_deleted',v_notif);
end;
$$;
revoke all on function admin_reset_client_data(uuid) from public;
grant execute on function admin_reset_client_data(uuid) to authenticated;

create or replace function get_client_financial_summary(p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_org uuid:=current_org_id(); v_result jsonb;
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  if not exists(select 1 from profiles where id=p_user_id and org_id=v_org) then raise exception 'client_not_found'; end if;
  select jsonb_build_object(
    'billing_profile',coalesce((select to_jsonb(x) from (
      select coalesce(cbp.model_override,bs.default_model,'pay_per_session') model,
        cbp.custom_price,cbp.notes from billing_settings bs left join client_billing_profiles cbp
        on cbp.org_id=bs.org_id and cbp.user_id=p_user_id where bs.org_id=v_org
    ) x),jsonb_build_object('model','pay_per_session','custom_price',null,'notes',null)),
    'packages',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,label,total_sessions,remaining_sessions,expires_at,status,price,created_at
      from client_packages where org_id=v_org and user_id=p_user_id order by created_at desc limit 20
    ) x),'[]'::jsonb),
    'memberships',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,plan_label,period_start,period_end,lessons_quota,lessons_used,status,auto_renew,price,created_at
      from client_memberships where org_id=v_org and user_id=p_user_id order by created_at desc limit 20
    ) x),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select id,amount,currency,method,kind,note,period_start,period_end,created_at,reversed_payment_id
      from payments where org_id=v_org and client_user_id=p_user_id order by created_at desc limit 50
    ) x),'[]'::jsonb),
    'totals',jsonb_build_object(
      'collected',coalesce((select sum(amount) from payments where org_id=v_org and client_user_id=p_user_id),0),
      'unpaid',coalesce((select sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type))) from bookings b
        where b.org_id=v_org and b.user_id=p_user_id and not b.paid and b.date<=current_date
          and b.status in ('confirmed','cancellation_requested')),0),
      'unpaid_count',(select count(*) from bookings b where b.org_id=v_org and b.user_id=p_user_id
        and not b.paid and b.date<=current_date and b.status in ('confirmed','cancellation_requested'))
    ),
    'health',jsonb_build_object(
      'archived',(select archived_at is not null from profiles where id=p_user_id),
      'medical_cert_expired',coalesce((select medical_cert_expiry<current_date from profiles where id=p_user_id),false),
      'insurance_expired',coalesce((select insurance_expiry<current_date from profiles where id=p_user_id),false),
      'active_package',exists(select 1 from client_packages where org_id=v_org and user_id=p_user_id
        and status='active' and remaining_sessions>0 and (expires_at is null or expires_at>=current_date)),
      'active_membership',exists(select 1 from client_memberships where org_id=v_org and user_id=p_user_id
        and status='active' and period_start<=current_date and period_end>=current_date),
      'unpaid_over_threshold',coalesce((select sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type)))
        from bookings b where b.org_id=v_org and b.user_id=p_user_id and not b.paid and b.date<=current_date
          and b.status in ('confirmed','cancellation_requested')),0)>
        coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)
        and coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)>0
    )
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function get_client_financial_summary(uuid) from public;
grant execute on function get_client_financial_summary(uuid) to authenticated;

-- Archived clients no longer consume a paid-plan client seat.
create or replace function org_at_client_limit(p_org_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select case when p.max_clients is null then false else
    (select count(*) from profiles pr where pr.org_id=p_org_id and pr.archived_at is null)>=p.max_clients end
  from subscriptions s join plans p on p.id=s.plan_id where s.org_id=p_org_id
$$;
revoke all on function org_at_client_limit(uuid) from public,anon;
grant execute on function org_at_client_limit(uuid) to authenticated,service_role;

create or replace function get_tenant_entitlements()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object('plan',p.code,'status',s.status,'max_clients',p.max_clients,
    'features',coalesce(p.features,'{}'::jsonb),'trial_end',s.trial_end,
    'current_period_end',s.current_period_end,
    'clients_count',(select count(*) from profiles where org_id=current_org_id() and archived_at is null))
  from subscriptions s left join plans p on p.id=s.plan_id where s.org_id=current_org_id()
$$;
revoke all on function get_tenant_entitlements() from public,anon;
grant execute on function get_tenant_entitlements() to authenticated;
