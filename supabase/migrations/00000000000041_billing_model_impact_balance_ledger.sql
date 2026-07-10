-- Allinea get_billing_model_change_impact/admin_save_default_billing_model al
-- conto cliente introdotto dalla 00040: il vecchio filtro "not paid" ignorava
-- le prenotazioni gia addebitate sul ledger (client_balance_entries), quindi
-- l'impatto di un cambio modello risultava sottostimato.

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
