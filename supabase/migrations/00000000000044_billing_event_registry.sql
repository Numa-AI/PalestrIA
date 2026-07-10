-- Registro economico completo e idempotente per lezioni, pacchetti e abbonamenti.
-- Gli eventi automatici (cron all'inizio lezione) vengono salvati lato server:
-- il Registro non deve ricostruirli dai soli flag correnti della prenotazione.

alter table admin_audit_log
  add column if not exists event_key text;

create unique index if not exists admin_audit_log_org_event_key_uidx
  on admin_audit_log(org_id,event_key);

create or replace function audit_balance_entry_for_registry()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_action text;
  v_name text;
  v_date date;
  v_time text;
  v_slot text;
begin
  v_action:=case new.kind
    when 'lesson_charge' then 'lesson_charge_applied'
    when 'lesson_reversal' then 'lesson_charge_reversed'
    when 'booking_payment' then 'lesson_payment_recorded'
    when 'lesson_waiver' then 'lesson_waived'
    when 'waiver_reversal' then 'lesson_waiver_reversed'
    when 'manual_credit' then 'client_credit_added'
    when 'manual_debt' then 'client_debt_added'
    when 'manual_payment' then 'client_payment_recorded'
    when 'model_reset' then 'client_balance_reset'
    else 'client_balance_changed'
  end;

  select p.name into v_name
  from profiles p where p.id=new.user_id and p.org_id=new.org_id;
  if new.booking_id is not null then
    select b.date,b.time,b.slot_type into v_date,v_time,v_slot
    from bookings b where b.id=new.booking_id and b.org_id=new.org_id;
  end if;

  insert into admin_audit_log(
    org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
  ) values(
    new.org_id,new.created_by,v_action,'client_balance_entry',new.id::text,
    jsonb_build_object(
      'client_user_id',new.user_id,
      'client_name',coalesce(v_name,'Cliente'),
      'booking_id',new.booking_id,
      'payment_id',new.payment_id,
      'balance_kind',new.kind,
      'amount',new.amount,
      'note',new.note,
      'lesson_date',v_date,
      'lesson_time',v_time,
      'slot_type',v_slot,
      'billing_model','pay_per_session'
    ),
    coalesce(new.effective_at,new.created_at,now()),
    'balance-entry:'||new.id::text
  ) on conflict (org_id,event_key) do nothing;
  return new;
end;
$$;

revoke all on function audit_balance_entry_for_registry() from public,anon,authenticated;
drop trigger if exists audit_balance_entry_for_registry on client_balance_entries;
create trigger audit_balance_entry_for_registry
  after insert on client_balance_entries for each row
  execute function audit_balance_entry_for_registry();

create or replace function audit_booking_billing_for_registry()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_action text;
  v_amount numeric;
begin
  v_action:=case coalesce(new.billing_model_snapshot,'pay_per_session')
    when 'package' then 'package_lesson_reserved'
    when 'monthly' then 'membership_lesson_used'
    when 'free' then 'free_lesson_booked'
    else 'lesson_booked'
  end;
  v_amount:=case when new.billing_model_snapshot='pay_per_session'
    then coalesce(new.custom_price,get_org_price(new.org_id,new.slot_type),0)
    else null end;

  insert into admin_audit_log(
    org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
  ) values(
    new.org_id,new.created_by,v_action,'booking',new.id::text,
    jsonb_build_object(
      'booking_id',new.id,
      'client_user_id',new.user_id,
      'client_name',new.name,
      'client_email',new.email,
      'client_phone',new.whatsapp,
      'billing_model',coalesce(new.billing_model_snapshot,'pay_per_session'),
      'package_id',coalesce(new.reserved_package_id,new.consumed_package_id),
      'membership_id',new.consumed_membership_id,
      'lesson_date',new.date,
      'lesson_time',new.time,
      'slot_type',new.slot_type,
      'amount',v_amount,
      'payment_method',new.payment_method,
      'note',new.notes
    ),
    new.created_at,
    'booking-billing:'||new.id::text
  ) on conflict (org_id,event_key) do nothing;
  return new;
end;
$$;

revoke all on function audit_booking_billing_for_registry() from public,anon,authenticated;
drop trigger if exists audit_booking_billing_for_registry on bookings;
create trigger audit_booking_billing_for_registry
  after insert on bookings for each row
  execute function audit_booking_billing_for_registry();

create or replace function audit_booking_billing_transition_for_registry()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_action text;
  v_target uuid;
begin
  if old.consumed_package_id is null and new.consumed_package_id is not null then
    v_action:='package_lesson_consumed'; v_target:=new.consumed_package_id;
  elsif old.consumed_package_id is not null and new.consumed_package_id is null then
    v_action:='package_lesson_restored'; v_target:=old.consumed_package_id;
  elsif old.reserved_package_id is not null and new.reserved_package_id is null
        and new.consumed_package_id is null then
    v_action:='package_reservation_released'; v_target:=old.reserved_package_id;
  elsif old.consumed_membership_id is not null and new.consumed_membership_id is null then
    v_action:='membership_lesson_restored'; v_target:=old.consumed_membership_id;
  else
    return new;
  end if;

  insert into admin_audit_log(
    org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
  ) values(
    new.org_id,auth.uid(),v_action,'booking',new.id::text,
    jsonb_build_object(
      'booking_id',new.id,
      'client_user_id',new.user_id,
      'client_name',new.name,
      'billing_model',new.billing_model_snapshot,
      'package_id',case when v_action like 'package_%' then v_target else null end,
      'membership_id',case when v_action like 'membership_%' then v_target else null end,
      'lesson_date',new.date,
      'lesson_time',new.time,
      'slot_type',new.slot_type,
      'status',new.status,
      'note',new.billing_void_reason
    ),
    coalesce(new.package_consumed_at,new.cancelled_at,new.updated_at,now()),
    v_action||':'||new.id::text
  ) on conflict (org_id,event_key) do nothing;
  return new;
end;
$$;

revoke all on function audit_booking_billing_transition_for_registry() from public,anon,authenticated;
drop trigger if exists audit_booking_billing_transition_for_registry on bookings;
create trigger audit_booking_billing_transition_for_registry
  after update of consumed_package_id,reserved_package_id,consumed_membership_id,status,billing_voided_at
  on bookings for each row
  execute function audit_booking_billing_transition_for_registry();

-- Backfill: rende il Registro completo anche per i movimenti precedenti al deploy.
insert into admin_audit_log(
  org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
)
select e.org_id,e.created_by,
  case e.kind
    when 'lesson_charge' then 'lesson_charge_applied'
    when 'lesson_reversal' then 'lesson_charge_reversed'
    when 'booking_payment' then 'lesson_payment_recorded'
    when 'lesson_waiver' then 'lesson_waived'
    when 'waiver_reversal' then 'lesson_waiver_reversed'
    when 'manual_credit' then 'client_credit_added'
    when 'manual_debt' then 'client_debt_added'
    when 'manual_payment' then 'client_payment_recorded'
    when 'model_reset' then 'client_balance_reset'
    else 'client_balance_changed' end,
  'client_balance_entry',e.id::text,
  jsonb_build_object(
    'client_user_id',e.user_id,'client_name',coalesce(p.name,'Cliente'),
    'booking_id',e.booking_id,'payment_id',e.payment_id,'balance_kind',e.kind,
    'amount',e.amount,'note',e.note,'lesson_date',b.date,'lesson_time',b.time,
    'slot_type',b.slot_type,'billing_model','pay_per_session'
  ),coalesce(e.effective_at,e.created_at),'balance-entry:'||e.id::text
from client_balance_entries e
left join profiles p on p.id=e.user_id and p.org_id=e.org_id
left join bookings b on b.id=e.booking_id and b.org_id=e.org_id
on conflict (org_id,event_key) do nothing;

-- I log vendita già presenti nelle migration precedenti non memorizzavano il
-- nome: lo aggiungiamo senza alterare azione, importo o timestamp storico.
update admin_audit_log a set metadata=a.metadata||jsonb_build_object(
  'client_name',p.name,'client_email',p.email
)
from profiles p
where a.org_id=p.org_id
  and case when coalesce(a.metadata->>'client_user_id','')
      ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    then (a.metadata->>'client_user_id')::uuid else null end=p.id
  and coalesce(a.metadata->>'client_name','')='';

insert into admin_audit_log(
  org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
)
select b.org_id,b.created_by,
  case coalesce(b.billing_model_snapshot,'pay_per_session')
    when 'package' then 'package_lesson_reserved'
    when 'monthly' then 'membership_lesson_used'
    when 'free' then 'free_lesson_booked'
    else 'lesson_booked' end,
  'booking',b.id::text,
  jsonb_build_object(
    'booking_id',b.id,'client_user_id',b.user_id,'client_name',b.name,
    'client_email',b.email,'client_phone',b.whatsapp,
    'billing_model',coalesce(b.billing_model_snapshot,'pay_per_session'),
    'package_id',coalesce(b.reserved_package_id,b.consumed_package_id),
    'membership_id',b.consumed_membership_id,'lesson_date',b.date,
    'lesson_time',b.time,'slot_type',b.slot_type,
    'amount',case when b.billing_model_snapshot='pay_per_session'
      then coalesce(b.custom_price,get_org_price(b.org_id,b.slot_type),0) else null end,
    'payment_method',b.payment_method,'note',b.notes
  ),b.created_at,'booking-billing:'||b.id::text
from bookings b
on conflict (org_id,event_key) do nothing;

insert into admin_audit_log(
  org_id,actor_user_id,action,target_type,target_id,metadata,created_at,event_key
)
select b.org_id,null,'package_lesson_consumed','booking',b.id::text,
  jsonb_build_object(
    'booking_id',b.id,'client_user_id',b.user_id,'client_name',b.name,
    'billing_model','package','package_id',b.consumed_package_id,
    'lesson_date',b.date,'lesson_time',b.time,'slot_type',b.slot_type
  ),coalesce(b.package_consumed_at,b.paid_at,b.created_at),
  'package_lesson_consumed:'||b.id::text
from bookings b where b.consumed_package_id is not null
on conflict (org_id,event_key) do nothing;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(select 1 from pg_publication_tables
       where pubname='supabase_realtime' and schemaname='public' and tablename='admin_audit_log') then
    alter publication supabase_realtime add table public.admin_audit_log;
  end if;
end;
$$;
