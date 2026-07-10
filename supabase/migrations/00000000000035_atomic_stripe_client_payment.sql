-- Stripe webhook entry point. Package/membership and ledger row are committed
-- in one database transaction and deduplicated by PaymentIntent.

create or replace function record_stripe_client_payment(
  p_org_id uuid,p_payment_intent text,p_kind text,p_amount numeric,p_currency text,
  p_client_user_id uuid default null,p_client_email text default null,
  p_booking_id uuid default null,p_total_sessions integer default null,
  p_package_label text default null,p_expires_at date default null,
  p_plan_label text default null,p_period_start date default null,
  p_period_end date default null,p_lessons_quota integer default null,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_payment uuid; v_package uuid; v_membership uuid;
begin
  if auth.role()<>'service_role' then raise exception 'unauthorized'; end if;
  if not exists(select 1 from organizations where id=p_org_id) then raise exception 'org_not_found'; end if;
  if nullif(trim(coalesce(p_payment_intent,'')),'') is null then raise exception 'missing_payment_intent'; end if;
  if p_kind not in ('session','package_purchase','membership') then raise exception 'invalid_kind'; end if;
  if p_amount is null or p_amount<0 or p_amount>1000000 then raise exception 'invalid_amount'; end if;
  if p_client_user_id is not null and not exists(
    select 1 from profiles where id=p_client_user_id and org_id=p_org_id and archived_at is null
  ) then raise exception 'client_not_found_or_archived'; end if;
  perform pg_advisory_xact_lock(hashtext(p_org_id::text||'|stripe|'||p_payment_intent));
  select id,package_id,membership_id into v_payment,v_package,v_membership from payments
    where stripe_payment_intent=p_payment_intent;
  if found then
    return jsonb_build_object('payment_id',v_payment,'package_id',v_package,
      'membership_id',v_membership,'idempotent',true);
  end if;
  if p_kind='session' then
    if p_booking_id is null or not exists(select 1 from bookings where id=p_booking_id and org_id=p_org_id) then
      raise exception 'booking_not_found';
    end if;
  elsif p_kind='package_purchase' then
    if p_client_user_id is null or p_total_sessions is null or p_total_sessions<=0 or p_total_sessions>10000 then
      raise exception 'invalid_package';
    end if;
    insert into client_packages(org_id,user_id,label,total_sessions,remaining_sessions,expires_at,price,status)
    values(p_org_id,p_client_user_id,coalesce(nullif(trim(p_package_label),''),'Pacchetto'),
      p_total_sessions,p_total_sessions,p_expires_at,p_amount,'active') returning id into v_package;
    insert into client_billing_profiles(org_id,user_id,client_email,model_override)
    values(p_org_id,p_client_user_id,lower(trim(p_client_email)),'package')
    on conflict(org_id,user_id) do update set client_email=excluded.client_email,
      model_override=excluded.model_override;
  else
    if p_client_user_id is null or p_period_start is null or p_period_end is null
       or p_period_end<p_period_start or (p_lessons_quota is not null and p_lessons_quota<=0) then
      raise exception 'invalid_membership';
    end if;
    insert into client_memberships(org_id,user_id,plan_label,period_start,period_end,
      lessons_quota,price,status)
    values(p_org_id,p_client_user_id,coalesce(nullif(trim(p_plan_label),''),'Abbonamento'),
      p_period_start,p_period_end,p_lessons_quota,p_amount,'active') returning id into v_membership;
    insert into client_billing_profiles(org_id,user_id,client_email,model_override)
    values(p_org_id,p_client_user_id,lower(trim(p_client_email)),'monthly')
    on conflict(org_id,user_id) do update set client_email=excluded.client_email,
      model_override=excluded.model_override;
  end if;
  insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
    booking_id,membership_id,package_id,period_start,period_end,note,
    stripe_payment_intent,idempotency_key)
  values(p_org_id,p_client_user_id,lower(trim(p_client_email)),p_amount,
    upper(coalesce(nullif(trim(p_currency),''),'EUR')),'stripe',p_kind,p_booking_id,
    v_membership,v_package,p_period_start,p_period_end,nullif(trim(coalesce(p_note,'')),''),
    p_payment_intent,'stripe:'||p_payment_intent) returning id into v_payment;
  if p_kind='session' then
    update bookings set paid=true,payment_method='stripe',paid_at=now()
      where id=p_booking_id and org_id=p_org_id;
  end if;
  insert into admin_audit_log(org_id,action,target_type,target_id,metadata)
  values(p_org_id,'stripe_client_payment','payment',v_payment::text,
    jsonb_build_object('kind',p_kind,'amount',p_amount,'payment_intent',p_payment_intent,
      'client_user_id',p_client_user_id));
  return jsonb_build_object('payment_id',v_payment,'package_id',v_package,
    'membership_id',v_membership,'idempotent',false);
end;
$$;
revoke all on function record_stripe_client_payment(uuid,text,text,numeric,text,uuid,text,uuid,integer,text,date,text,date,date,integer,text) from public,anon,authenticated;
grant execute on function record_stripe_client_payment(uuid,text,text,numeric,text,uuid,text,uuid,integer,text,date,text,date,date,integer,text) to service_role;
