-- Safe schedule overrides and lesson-date-aware billing eligibility.

create or replace function admin_upsert_schedule_override(
  p_date date,p_time text,p_slot_type_id uuid,p_capacity integer
) returns uuid
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id(); v_key text; v_id uuid;
  v_occupied integer; v_conflicting integer;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_date is null or p_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9] - ([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'invalid_slot'; end if;
  if p_capacity is null or p_capacity<0 or p_capacity>10000 then raise exception 'invalid_capacity'; end if;
  select key into v_key from slot_types where id=p_slot_type_id and org_id=v_org and is_active;
  if not found then raise exception 'slot_type_not_found'; end if;
  perform pg_advisory_xact_lock(hashtext(v_org::text||'|slot|'||p_date::text||'|'||p_time));
  select count(*),count(*) filter(where slot_type<>v_key) into v_occupied,v_conflicting
    from bookings where org_id=v_org and date=p_date and time=p_time
      and status in ('confirmed','cancellation_requested');
  if v_conflicting>0 then raise exception 'override_type_conflicts_with_bookings'; end if;
  if p_capacity<v_occupied then raise exception 'capacity_below_occupancy'; end if;
  insert into schedule_overrides(org_id,date,time,slot_type,slot_type_id,capacity)
  values(v_org,p_date,p_time,v_key,p_slot_type_id,p_capacity)
  on conflict(org_id,date,time) do update set slot_type=excluded.slot_type,
    slot_type_id=excluded.slot_type_id,capacity=excluded.capacity
  returning id into v_id;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'schedule_override_saved','schedule_override',v_id::text,
    jsonb_build_object('date',p_date,'time',p_time,'slot_type',v_key,
      'capacity',p_capacity,'occupied',v_occupied));
  return v_id;
end;
$$;
revoke all on function admin_upsert_schedule_override(date,text,uuid,integer) from public;
grant execute on function admin_upsert_schedule_override(date,text,uuid,integer) to authenticated;

create or replace function admin_delete_schedule_override(p_date date,p_time text) returns void
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id(); v_cfg record; v_old uuid;
  v_occupied integer; v_conflicting integer;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  perform pg_advisory_xact_lock(hashtext(v_org::text||'|slot|'||p_date::text||'|'||p_time));
  delete from schedule_overrides where org_id=v_org and date=p_date and time=p_time returning id into v_old;
  if not found then raise exception 'override_not_found'; end if;
  select * into v_cfg from resolve_slot_config(v_org,p_date,p_time);
  select count(*),count(*) filter(where slot_type is distinct from v_cfg.slot_type)
    into v_occupied,v_conflicting from bookings
    where org_id=v_org and date=p_date and time=p_time
      and status in ('confirmed','cancellation_requested');
  if v_occupied>0 and (not coalesce(v_cfg.bookable,false) or v_conflicting>0
      or v_occupied>coalesce(v_cfg.capacity,0)) then
    raise exception 'fallback_cannot_hold_bookings';
  end if;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'schedule_override_deleted','schedule_override',v_old::text,
    jsonb_build_object('date',p_date,'time',p_time));
end;
$$;
revoke all on function admin_delete_schedule_override(date,text) from public;
grant execute on function admin_delete_schedule_override(date,text) to authenticated;

create or replace function book_slot(
  p_org_slug text,p_local_id text,p_date text,p_time text,p_name text,p_email text,
  p_whatsapp text,p_notes text,p_date_display text default '',p_for_user_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid; v_uid uuid:=auth.uid(); v_book_user uuid; v_email_owner uuid;
  v_email text:=lower(trim(coalesce(p_email,''))); v_cfg record;
  v_count integer; v_id uuid; v_is_admin boolean:=false;
  v_start_time time; v_lesson_dt timestamptz; v_tz text; v_model text;
  v_pkg client_packages%rowtype; v_mem client_memberships%rowtype;
  v_pkg_id uuid:=null; v_mem_id uuid:=null; v_paid boolean:=false; v_method text:=null;
  v_grace integer:=0; v_unpaid numeric:=0; v_threshold numeric:=0;
begin
  v_org:=coalesce(org_id_for_slug(p_org_slug),current_org_id());
  if v_org is null then return jsonb_build_object('success',false,'error','org_not_found'); end if;
  v_is_admin:=is_org_admin(v_org);
  select timezone into v_tz from organizations where id=v_org;
  v_tz:=coalesce(v_tz,'Europe/Rome');

  if v_email<>'' and v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' then
    return jsonb_build_object('success',false,'error','invalid_email');
  end if;
  if p_name is null or trim(p_name)='' then return jsonb_build_object('success',false,'error','missing_name'); end if;
  if p_date::date<current_date and not v_is_admin then return jsonb_build_object('success',false,'error','past_date'); end if;

  select id into v_email_owner from profiles where org_id=v_org and lower(email)=v_email;
  if p_for_user_id is not null and v_is_admin
     and not exists(select 1 from profiles where id=p_for_user_id and org_id=v_org and archived_at is null) then
    return jsonb_build_object('success',false,'error','client_not_found');
  end if;
  if p_for_user_id is not null and v_is_admin
     and exists(select 1 from profiles where id=p_for_user_id and org_id=v_org and archived_at is null) then
    v_book_user:=p_for_user_id;
    select lower(email) into v_email from profiles where id=p_for_user_id and org_id=v_org;
  elsif v_uid is not null
     and exists(select 1 from profiles where id=v_uid and org_id=v_org and archived_at is null) then
    v_book_user:=v_uid;
    if v_email_owner is not null and v_email_owner<>v_uid then
      return jsonb_build_object('success',false,'error','identity_mismatch');
    end if;
    select lower(email) into v_email from profiles where id=v_uid and org_id=v_org;
  elsif v_email_owner is not null then
    if exists(select 1 from profiles where id=v_email_owner and archived_at is not null) then
      return jsonb_build_object('success',false,'error','client_archived');
    end if;
    return jsonb_build_object('success',false,'error','login_required');
  else
    v_book_user:=null;
  end if;

  -- The local id is the booking idempotency key. The lock + lookup prevents a
  -- timeout retry from consuming a second package session.
  if nullif(trim(coalesce(p_local_id,'')),'') is not null then
    perform pg_advisory_xact_lock(hashtext(v_org::text||'|booking|'||p_local_id));
    select id,paid into v_id,v_paid from bookings where org_id=v_org and local_id=p_local_id order by created_at limit 1;
    if found then return jsonb_build_object('success',true,'booking_id',v_id::text,'paid',v_paid,'idempotent',true); end if;
  end if;

  select * into v_cfg from resolve_slot_config(v_org,p_date::date,p_time);
  if not coalesce(v_cfg.bookable,false) or coalesce(v_cfg.capacity,0)<=0 then
    return jsonb_build_object('success',false,'error','not_bookable');
  end if;
  if not v_is_admin then
    v_start_time:=split_part(p_time,' - ',1)::time;
    v_lesson_dt:=(p_date::date+v_start_time) at time zone v_tz;
    if now()>v_lesson_dt+interval '30 minutes' then return jsonb_build_object('success',false,'error','too_late'); end if;
  end if;
  if not pg_try_advisory_xact_lock(hashtext(v_org::text||'|'||p_date||'|'||p_time||'|'||v_cfg.slot_type)) then
    return jsonb_build_object('success',false,'error','slot_busy');
  end if;
  select count(*) into v_count from bookings where org_id=v_org and date=p_date::date and time=p_time
    and slot_type=v_cfg.slot_type and status in ('confirmed','cancellation_requested');
  if v_count>=v_cfg.capacity then return jsonb_build_object('success',false,'error','slot_full'); end if;

  if v_book_user is not null then
    select
      coalesce(
        (select cbp.model_override from client_billing_profiles cbp
          where cbp.org_id=v_org and cbp.user_id=v_book_user),
        (select bs.default_model from billing_settings bs where bs.org_id=v_org),
        'pay_per_session'
      ),
      coalesce((select bs.grace_days from billing_settings bs where bs.org_id=v_org),0),
      coalesce((select bs.block_unpaid_threshold from billing_settings bs where bs.org_id=v_org),0)
      into v_model,v_grace,v_threshold;
    if v_model='free' then v_paid:=true; v_method:='gratuito';
    elsif v_model='package' then
      select * into v_pkg from client_packages where org_id=v_org and user_id=v_book_user
        and status='active' and remaining_sessions>0
        and (expires_at is null or expires_at>=p_date::date)
        order by purchased_at asc limit 1 for update;
      if not found then
        if coalesce((select block_if_no_package from billing_settings where org_id=v_org),true) then
          return jsonb_build_object('success',false,'error','no_package');
        end if;
      else
        update client_packages set remaining_sessions=remaining_sessions-1,
          status=case when remaining_sessions-1<=0 then 'exhausted' else status end where id=v_pkg.id;
        v_pkg_id:=v_pkg.id; v_paid:=true; v_method:='pacchetto';
      end if;
    elsif v_model='monthly' then
      select * into v_mem from client_memberships where org_id=v_org and user_id=v_book_user
        and status='active' and period_start<=p_date::date
        and period_end>=p_date::date-make_interval(days=>v_grace)
        order by period_end asc limit 1 for update;
      if not found then
        if coalesce((select block_if_membership_expired from billing_settings where org_id=v_org),true) then
          return jsonb_build_object('success',false,'error','membership_expired');
        end if;
      elsif v_mem.lessons_quota is not null and v_mem.lessons_used>=v_mem.lessons_quota then
        return jsonb_build_object('success',false,'error','quota_exceeded');
      else
        update client_memberships set lessons_used=lessons_used+1 where id=v_mem.id;
        v_mem_id:=v_mem.id; v_paid:=true; v_method:='abbonamento';
      end if;
    elsif v_model='pay_per_session' and v_threshold>0 then
      select coalesce(sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type))),0)
        into v_unpaid from bookings b where b.org_id=v_org and b.user_id=v_book_user
          and not b.paid and b.date<=current_date
          and b.status in ('confirmed','cancellation_requested');
      if v_unpaid>=v_threshold then
        return jsonb_build_object('success',false,'error','outstanding_balance','amount',v_unpaid);
      end if;
    end if;
  end if;

  insert into bookings(org_id,local_id,user_id,date,time,slot_type,slot_type_id,name,email,
    whatsapp,notes,status,created_at,date_display,created_by,paid,payment_method,paid_at,
    consumed_package_id,consumed_membership_id)
  values(v_org,p_local_id,v_book_user,p_date::date,p_time,v_cfg.slot_type,v_cfg.slot_type_id,
    trim(p_name),nullif(v_email,''),nullif(trim(coalesce(p_whatsapp,'')),''),p_notes,'confirmed',
    now(),p_date_display,v_uid,v_paid,v_method,case when v_paid then now() else null end,
    v_pkg_id,v_mem_id) returning id into v_id;
  return jsonb_build_object('success',true,'booking_id',v_id::text,'paid',v_paid);
exception
  when invalid_text_representation or datetime_field_overflow then
    return jsonb_build_object('success',false,'error','invalid_date_or_time');
end;
$$;
revoke all on function book_slot from public;
grant execute on function book_slot to anon,authenticated;
