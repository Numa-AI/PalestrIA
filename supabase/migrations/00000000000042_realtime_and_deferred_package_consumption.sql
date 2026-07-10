-- Billing live + consumo pacchetto all'inizio effettivo della lezione.
-- Corregge inoltre il cast rigido degli orari legacy nel processore saldo.

alter table bookings
  add column if not exists reserved_package_id uuid,
  add column if not exists package_consumed_at timestamptz;
create index if not exists bookings_reserved_package_idx
  on bookings(org_id,reserved_package_id)
  where reserved_package_id is not null and status in ('confirmed','cancellation_requested');

-- Parser tollerante: una vecchia riga con orario non standard non deve mai
-- interrompere book_slot o il job di tutta l'organizzazione.
create or replace function safe_booking_start_at(p_date date,p_time text,p_timezone text)
returns timestamptz
language plpgsql stable set search_path=public as $$
declare v_hm text;
begin
  v_hm:=substring(coalesce(p_time,'') from '([0-2]?[0-9]:[0-5][0-9])');
  if v_hm is null then return null; end if;
  return (p_date+v_hm::time) at time zone coalesce(nullif(p_timezone,''),'Europe/Rome');
exception when invalid_text_representation or datetime_field_overflow or invalid_parameter_value then
  return null;
end;
$$;
revoke all on function safe_booking_start_at(date,text,text) from public,anon;
grant execute on function safe_booking_start_at(date,text,text) to authenticated,service_role;

create or replace function process_due_session_balance_entries(
  p_org_id uuid default null,p_limit integer default 2000
) returns integer
language plpgsql security definer set search_path=public as $$
declare v_count integer:=0;
begin
  if p_limit is null or p_limit<1 or p_limit>10000 then raise exception 'invalid_limit'; end if;
  insert into client_balance_entries(
    org_id,user_id,booking_id,kind,amount,note,effective_at,idempotency_key
  )
  select b.org_id,b.user_id,b.id,'lesson_charge',
    -round(coalesce(b.custom_price,get_org_price(b.org_id,b.slot_type),0)::numeric,2),
    'Addebito lezione '||b.date::text||' '||coalesce(substring(b.time from '([0-2]?[0-9]:[0-5][0-9])'),b.time),
    s.start_at,'lesson-charge:'||b.id::text
  from bookings b
  join organizations o on o.id=b.org_id
  cross join lateral (select safe_booking_start_at(b.date,b.time,o.timezone) start_at) s
  where (p_org_id is null or b.org_id=p_org_id)
    and b.user_id is not null and b.billing_model_snapshot='pay_per_session'
    and b.billing_voided_at is null
    and b.status in ('confirmed','cancellation_requested')
    and s.start_at is not null and s.start_at<=now()
    and not exists(select 1 from client_balance_entries e
      where e.org_id=b.org_id and e.booking_id=b.id and e.kind='lesson_charge')
  order by s.start_at,b.id
  limit p_limit
  on conflict (org_id,idempotency_key) do nothing;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function process_due_session_balance_entries(uuid,integer) from public,anon,authenticated;
grant execute on function process_due_session_balance_entries(uuid,integer) to service_role;

-- Le prenotazioni future gia scalate dalle versioni precedenti tornano a essere
-- semplici riserve; gli ingressi vengono restituiti una sola volta al pacchetto.
with reserved as (
  select b.org_id,b.consumed_package_id package_id,count(*)::integer qty
  from bookings b join organizations o on o.id=b.org_id
  where b.consumed_package_id is not null
    and b.billing_model_snapshot='package'
    and b.billing_voided_at is null
    and b.status in ('confirmed','cancellation_requested')
    and safe_booking_start_at(b.date,b.time,o.timezone)>now()
  group by b.org_id,b.consumed_package_id
)
update client_packages p set
  remaining_sessions=least(p.total_sessions,p.remaining_sessions+r.qty),
  status=case when p.status='exhausted' then 'active' else p.status end
from reserved r where p.id=r.package_id and p.org_id=r.org_id;

update bookings b set
  reserved_package_id=b.consumed_package_id,consumed_package_id=null,package_consumed_at=null
from organizations o
where o.id=b.org_id and b.consumed_package_id is not null
  and b.billing_model_snapshot='package' and b.billing_voided_at is null
  and b.status in ('confirmed','cancellation_requested')
  and safe_booking_start_at(b.date,b.time,o.timezone)>now();

update bookings b set package_consumed_at=coalesce(package_consumed_at,
  safe_booking_start_at(b.date,b.time,o.timezone),b.paid_at,b.created_at)
from organizations o where o.id=b.org_id and b.consumed_package_id is not null
  and b.package_consumed_at is null;

create or replace function process_due_package_consumptions(
  p_org_id uuid default null,p_limit integer default 2000
) returns integer
language plpgsql security definer set search_path=public as $$
declare v_booking record; v_count integer:=0; v_package uuid;
begin
  if p_limit is null or p_limit<1 or p_limit>10000 then raise exception 'invalid_limit'; end if;
  for v_booking in
    select b.id,b.org_id,b.reserved_package_id,s.start_at
    from bookings b join organizations o on o.id=b.org_id
    cross join lateral (select safe_booking_start_at(b.date,b.time,o.timezone) start_at) s
    where (p_org_id is null or b.org_id=p_org_id)
      and b.reserved_package_id is not null and b.consumed_package_id is null
      and b.billing_model_snapshot='package' and b.billing_voided_at is null
      and b.status in ('confirmed','cancellation_requested')
      and s.start_at is not null and s.start_at<=now()
    order by s.start_at,b.id limit p_limit for update of b skip locked
  loop
    v_package:=null;
    update client_packages set
      remaining_sessions=remaining_sessions-1,
      status=case when remaining_sessions-1<=0 then 'exhausted' else status end
    where id=v_booking.reserved_package_id and org_id=v_booking.org_id
      and status in ('active','exhausted') and remaining_sessions>0
    returning id into v_package;
    if v_package is not null then
      update bookings set consumed_package_id=v_package,reserved_package_id=null,
        package_consumed_at=v_booking.start_at
      where id=v_booking.id and org_id=v_booking.org_id;
      v_count:=v_count+1;
    end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function process_due_package_consumptions(uuid,integer) from public,anon,authenticated;
grant execute on function process_due_package_consumptions(uuid,integer) to service_role;

create or replace function clear_package_reservation_on_booking_close()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status='cancelled' or new.billing_voided_at is not null then
    new.reserved_package_id:=null;
  end if;
  return new;
end;
$$;
drop trigger if exists clear_package_reservation_on_booking_close on bookings;
create trigger clear_package_reservation_on_booking_close
  before update of status,billing_voided_at on bookings for each row
  execute function clear_package_reservation_on_booking_close();

-- book_slot conserva la riserva del pacchetto ma non tocca remaining_sessions.
create or replace function book_slot(
  p_org_slug text,p_local_id text,p_date text,p_time text,p_name text,p_email text,
  p_whatsapp text,p_notes text,p_date_display text default '',p_for_user_id uuid default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid; v_uid uuid:=auth.uid(); v_book_user uuid; v_email_owner uuid;
  v_email text:=lower(trim(coalesce(p_email,''))); v_cfg record;
  v_count integer; v_id uuid; v_is_admin boolean:=false;
  v_lesson_dt timestamptz; v_tz text; v_model text;
  v_pkg client_packages%rowtype; v_mem client_memberships%rowtype;
  v_reserved_pkg_id uuid:=null; v_mem_id uuid:=null; v_paid boolean:=false; v_method text:=null;
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
  else v_book_user:=null;
  end if;
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
    v_lesson_dt:=safe_booking_start_at(p_date::date,p_time,v_tz);
    if v_lesson_dt is null then return jsonb_build_object('success',false,'error','invalid_date_or_time'); end if;
    if now()>v_lesson_dt+interval '30 minutes' then return jsonb_build_object('success',false,'error','too_late'); end if;
  end if;
  if not pg_try_advisory_xact_lock(hashtext(v_org::text||'|'||p_date||'|'||p_time||'|'||v_cfg.slot_type)) then
    return jsonb_build_object('success',false,'error','slot_busy');
  end if;
  select count(*) into v_count from bookings where org_id=v_org and date=p_date::date and time=p_time
    and slot_type=v_cfg.slot_type and status in ('confirmed','cancellation_requested');
  if v_count>=v_cfg.capacity then return jsonb_build_object('success',false,'error','slot_full'); end if;
  if v_book_user is not null then
    select coalesce((select cbp.model_override from client_billing_profiles cbp
      where cbp.org_id=v_org and cbp.user_id=v_book_user),
      (select bs.default_model from billing_settings bs where bs.org_id=v_org),'pay_per_session'),
      coalesce((select bs.grace_days from billing_settings bs where bs.org_id=v_org),0),
      coalesce((select bs.block_unpaid_threshold from billing_settings bs where bs.org_id=v_org),0)
      into v_model,v_grace,v_threshold;
    if v_model='free' then v_paid:=true; v_method:='gratuito';
    elsif v_model='package' then
      select p.* into v_pkg from client_packages p
      where p.org_id=v_org and p.user_id=v_book_user and p.status='active'
        and (p.expires_at is null or p.expires_at>=p_date::date)
        and p.remaining_sessions>(select count(*) from bookings rb
          where rb.org_id=v_org and rb.reserved_package_id=p.id
            and rb.billing_voided_at is null
            and rb.status in ('confirmed','cancellation_requested'))
      order by p.purchased_at asc limit 1 for update of p;
      if not found then
        if coalesce((select block_if_no_package from billing_settings where org_id=v_org),true) then
          return jsonb_build_object('success',false,'error','no_package');
        end if;
      else
        v_reserved_pkg_id:=v_pkg.id; v_paid:=true; v_method:='pacchetto';
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
      perform process_due_session_balance_entries(v_org,10000);
      select greatest(-coalesce(sum(e.amount),0),0) into v_unpaid
        from client_balance_entries e where e.org_id=v_org and e.user_id=v_book_user;
      if v_unpaid>=v_threshold then
        return jsonb_build_object('success',false,'error','outstanding_balance','amount',v_unpaid);
      end if;
    end if;
  end if;
  insert into bookings(org_id,local_id,user_id,date,time,slot_type,slot_type_id,name,email,
    whatsapp,notes,status,created_at,date_display,created_by,paid,payment_method,paid_at,
    consumed_package_id,reserved_package_id,consumed_membership_id)
  values(v_org,p_local_id,v_book_user,p_date::date,p_time,v_cfg.slot_type,v_cfg.slot_type_id,
    trim(p_name),nullif(v_email,''),nullif(trim(coalesce(p_whatsapp,'')),''),p_notes,'confirmed',
    now(),p_date_display,v_uid,v_paid,v_method,case when v_paid then now() else null end,
    null,v_reserved_pkg_id,v_mem_id) returning id into v_id;
  return jsonb_build_object('success',true,'booking_id',v_id::text,'paid',v_paid);
exception when invalid_text_representation or datetime_field_overflow then
  return jsonb_build_object('success',false,'error','invalid_date_or_time');
end;
$$;
revoke all on function book_slot from public;
grant execute on function book_slot to anon,authenticated;

-- Realtime deve essere abilitato esplicitamente: senza publication Flutter e
-- PWA ricevono i dati solo dopo pull-to-refresh.
do $$
declare v_table text;
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    foreach v_table in array array['client_balance_entries','payments','client_packages','client_memberships','bookings'] loop
      if not exists(select 1 from pg_publication_tables
        where pubname='supabase_realtime' and schemaname='public' and tablename=v_table) then
        execute format('alter publication supabase_realtime add table public.%I',v_table);
      end if;
    end loop;
  end if;
end;
$$;

do $$
declare v_job bigint;
begin
  for v_job in select jobid from cron.job where jobname='palestria-charge-lessons-at-start' loop
    perform cron.unschedule(v_job);
  end loop;
  perform cron.schedule('palestria-charge-lessons-at-start','* * * * *',
    $cron$select public.process_due_session_balance_entries(null,10000); select public.process_due_package_consumptions(null,10000);$cron$);
end;
$$;
