-- Conto cliente append-only per il modello a entrata.
-- Segno: positivo = credito del cliente, negativo = debito del cliente.
-- L'addebito della lezione nasce soltanto quando scatta l'orario di inizio.

alter table bookings
  add column if not exists billing_model_snapshot text;
alter table bookings drop constraint if exists bookings_billing_model_snapshot_check;
alter table bookings add constraint bookings_billing_model_snapshot_check
  check (billing_model_snapshot is null or billing_model_snapshot in
    ('pay_per_session','package','monthly','free'));

alter table payments drop constraint if exists payments_kind_check;
alter table payments add constraint payments_kind_check check (kind in
  ('session','membership','package_purchase','penalty_mora','adjustment','account_credit'));

create table if not exists client_balance_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  booking_id uuid references bookings(id) on delete set null,
  payment_id uuid references payments(id) on delete set null,
  kind text not null check (kind in (
    'lesson_charge','lesson_reversal','booking_payment','lesson_waiver',
    'waiver_reversal','manual_credit','manual_debt','manual_payment','model_reset'
  )),
  amount numeric(12,2) not null,
  note text,
  effective_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  idempotency_key text not null,
  unique (org_id,idempotency_key)
);
create index if not exists client_balance_entries_org_user_idx
  on client_balance_entries(org_id,user_id,effective_at desc);
create unique index if not exists client_balance_entries_payment_uidx
  on client_balance_entries(payment_id) where payment_id is not null;
create unique index if not exists client_balance_entries_booking_charge_uidx
  on client_balance_entries(booking_id) where kind='lesson_charge' and booking_id is not null;

alter table client_balance_entries enable row level security;
drop policy if exists client_balance_entries_select on client_balance_entries;
create policy client_balance_entries_select on client_balance_entries
  for select to authenticated using (
    org_id=current_org_id() and (user_id=auth.uid() or is_org_admin(org_id) or is_org_staff(org_id))
  );
-- Nessuna scrittura diretta dal client: tutti i movimenti passano da RPC/trigger.

-- Congela sia il modello sia il prezzo che valgono quando nasce la prenotazione.
create or replace function apply_client_booking_price()
returns trigger
language plpgsql security definer set search_path=public as $$
declare
  v_model text;
  v_price numeric;
begin
  select coalesce(cbp.model_override,bs.default_model,'pay_per_session'),cbp.custom_price
    into v_model,v_price
    from billing_settings bs
    left join client_billing_profiles cbp
      on cbp.org_id=bs.org_id and cbp.user_id=new.user_id
    where bs.org_id=new.org_id;
  v_model:=case when v_model in ('quarterly','annual') then 'monthly'
    else coalesce(v_model,'pay_per_session') end;
  new.billing_model_snapshot:=coalesce(new.billing_model_snapshot,v_model);
  if new.billing_model_snapshot='pay_per_session' then
    new.custom_price:=coalesce(new.custom_price,v_price,get_org_price(new.org_id,new.slot_type),0);
  end if;
  return new;
end;
$$;
revoke all on function apply_client_booking_price() from public,anon,authenticated;

drop trigger if exists apply_client_booking_price_before_insert on bookings;
create trigger apply_client_booking_price_before_insert
  before insert on bookings for each row execute function apply_client_booking_price();

-- Backfill delle prenotazioni ancora operative. Le posizioni gia annullate da un
-- cambio modello non vengono riaperte.
update bookings b set billing_model_snapshot=case
  when b.consumed_package_id is not null then 'package'
  when b.consumed_membership_id is not null then 'monthly'
  when b.payment_method='gratuito' then 'pay_per_session'
  else coalesce((select case when cbp.model_override in ('quarterly','annual') then 'monthly'
    else cbp.model_override end from client_billing_profiles cbp
    where cbp.org_id=b.org_id and cbp.user_id=b.user_id),
    (select case when bs.default_model in ('quarterly','annual') then 'monthly'
      else bs.default_model end from billing_settings bs where bs.org_id=b.org_id),
    'pay_per_session') end
where b.billing_model_snapshot is null;

update bookings b set custom_price=coalesce(get_org_price(b.org_id,b.slot_type),0)
where b.billing_model_snapshot='pay_per_session' and b.custom_price is null;

-- Processore idempotente. p_org_id=null e usato dal cron per tutte le org;
-- le RPC di lettura gli passano sempre l'org corrente.
create or replace function process_due_session_balance_entries(
  p_org_id uuid default null,
  p_limit integer default 2000
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
    'Addebito lezione '||b.date::text||' '||split_part(b.time,' - ',1),
    ((b.date+split_part(b.time,' - ',1)::time) at time zone coalesce(o.timezone,'Europe/Rome')),
    'lesson-charge:'||b.id::text
  from bookings b
  join organizations o on o.id=b.org_id
  where (p_org_id is null or b.org_id=p_org_id)
    and b.user_id is not null
    and b.billing_model_snapshot='pay_per_session'
    and b.billing_voided_at is null
    and b.status in ('confirmed','cancellation_requested')
    and ((b.date+split_part(b.time,' - ',1)::time)
      at time zone coalesce(o.timezone,'Europe/Rome'))<=now()
    and not exists(select 1 from client_balance_entries e
      where e.org_id=b.org_id and e.booking_id=b.id and e.kind='lesson_charge')
  order by b.date,split_part(b.time,' - ',1)
  limit p_limit
  on conflict (org_id,idempotency_key) do nothing;
  get diagnostics v_count=row_count;
  return v_count;
end;
$$;
revoke all on function process_due_session_balance_entries(uuid,integer) from public,anon,authenticated;
grant execute on function process_due_session_balance_entries(uuid,integer) to service_role;

-- Ogni incasso a lezione/top-up registrato nel ledger del fatturato genera il
-- corrispondente credito nel conto cliente. Il metodo gratuito e una rinuncia
-- legata alla singola lezione, non fatturato.
create or replace function mirror_payment_to_client_balance()
returns trigger
language plpgsql security definer set search_path=public as $$
declare v_amount numeric; v_kind text;
begin
  if new.client_user_id is null then return new; end if;
  if new.kind='session' and new.booking_id is not null then
    if new.method='gratuito' then
      select round(coalesce(custom_price,get_org_price(org_id,slot_type),0)::numeric,2)
        into v_amount from bookings where id=new.booking_id and org_id=new.org_id;
      v_kind:='lesson_waiver';
    else
      v_amount:=new.amount; v_kind:='booking_payment';
    end if;
  elsif new.kind='account_credit' then
    v_amount:=new.amount; v_kind:='manual_payment';
  else
    return new;
  end if;
  insert into client_balance_entries(org_id,user_id,booking_id,payment_id,kind,amount,
    note,effective_at,created_by,idempotency_key)
  values(new.org_id,new.client_user_id,new.booking_id,new.id,v_kind,v_amount,
    coalesce(new.note,case when new.kind='session' then 'Pagamento lezione' else 'Versamento credito' end),
    new.created_at,new.created_by,'payment:'||new.id::text)
  on conflict (org_id,idempotency_key) do nothing;
  return new;
end;
$$;
revoke all on function mirror_payment_to_client_balance() from public,anon,authenticated;

drop trigger if exists mirror_payment_to_client_balance_after_insert on payments;
create trigger mirror_payment_to_client_balance_after_insert
  after insert on payments for each row execute function mirror_payment_to_client_balance();

-- Cancellare/eliminare una lezione gia iniziata non cancella l'addebito: crea
-- una restituzione. Una rinuncia gratuita collegata a quella lezione viene
-- contemporaneamente stornata, cosi non diventa credito spendibile altrove.
create or replace function reverse_lesson_balance_on_booking_removal()
returns trigger
language plpgsql security definer set search_path=public as $$
declare v_charge numeric; v_waiver numeric;
begin
  if tg_op='UPDATE' and not (old.status is distinct from 'cancelled' and new.status='cancelled') then
    return new;
  end if;
  select -sum(amount) into v_charge from client_balance_entries
    where org_id=old.org_id and booking_id=old.id and kind='lesson_charge';
  if coalesce(v_charge,0)<>0 then
    insert into client_balance_entries(org_id,user_id,booking_id,kind,amount,note,
      effective_at,created_by,idempotency_key)
    values(old.org_id,old.user_id,old.id,'lesson_reversal',v_charge,
      'Restituzione per lezione annullata',now(),auth.uid(),'lesson-reversal:'||old.id::text)
    on conflict (org_id,idempotency_key) do nothing;
  end if;
  select -sum(amount) into v_waiver from client_balance_entries
    where org_id=old.org_id and booking_id=old.id and kind='lesson_waiver';
  if coalesce(v_waiver,0)<>0 then
    insert into client_balance_entries(org_id,user_id,booking_id,kind,amount,note,
      effective_at,created_by,idempotency_key)
    values(old.org_id,old.user_id,old.id,'waiver_reversal',v_waiver,
      'Storno gratuitita per lezione annullata',now(),auth.uid(),'waiver-reversal:'||old.id::text)
    on conflict (org_id,idempotency_key) do nothing;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function reverse_lesson_balance_on_booking_removal() from public,anon,authenticated;

drop trigger if exists reverse_lesson_balance_on_booking_cancel on bookings;
create trigger reverse_lesson_balance_on_booking_cancel
  after update of status on bookings for each row execute function reverse_lesson_balance_on_booking_removal();
drop trigger if exists reverse_lesson_balance_on_booking_delete on bookings;
create trigger reverse_lesson_balance_on_booking_delete
  before delete on bookings for each row execute function reverse_lesson_balance_on_booking_removal();

-- Storico preesistente: incassi attivi diventano credito; subito dopo il
-- processore crea gli addebiti delle sole lezioni gia iniziate.
insert into client_balance_entries(org_id,user_id,booking_id,payment_id,kind,amount,
  note,effective_at,created_by,idempotency_key)
select p.org_id,p.client_user_id,p.booking_id,p.id,
  case when p.method='gratuito' then 'lesson_waiver' else 'booking_payment' end,
  case when p.method='gratuito' then round(coalesce(b.custom_price,get_org_price(b.org_id,b.slot_type),0)::numeric,2)
    else p.amount end,
  coalesce(p.note,'Pagamento lezione'),p.created_at,p.created_by,'payment:'||p.id::text
from payments p join bookings b on b.id=p.booking_id and b.org_id=p.org_id
where p.kind='session' and p.client_user_id is not null
  and b.status in ('confirmed','cancellation_requested')
on conflict (org_id,idempotency_key) do nothing;

select process_due_session_balance_entries(null,10000);

-- Operazione manuale unica per incasso, aggiunta credito e aggiunta debito.
create or replace function admin_record_client_balance_operation(
  p_user_id uuid,
  p_operation text,
  p_amount numeric,
  p_method text default null,
  p_note text default null,
  p_idempotency_key text default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid:=current_org_id(); v_email text; v_currency text; v_key text;
  v_payment uuid; v_entry uuid; v_signed numeric; v_kind text; v_balance numeric;
  v_model text;
begin
  if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
  if p_operation not in ('payment','credit','debt') then raise exception 'invalid_operation'; end if;
  if p_amount is null or p_amount<=0 or p_amount>1000000 then raise exception 'invalid_amount'; end if;
  if length(coalesce(p_note,''))>500 then raise exception 'invalid_note'; end if;
  if p_operation in ('payment','credit') and (p_method is null or p_method not in
    ('contanti','contanti-report','carta','iban','stripe','gratuito')) then raise exception 'invalid_method'; end if;
  select p.email,coalesce(cbp.model_override,bs.default_model,'pay_per_session')
    into v_email,v_model from profiles p
    join billing_settings bs on bs.org_id=p.org_id
    left join client_billing_profiles cbp on cbp.org_id=p.org_id and cbp.user_id=p.id
    where p.id=p_user_id and p.org_id=v_org and p.archived_at is null;
  if not found then raise exception 'client_not_found_or_archived'; end if;
  if v_model<>'pay_per_session' then raise exception 'operation_requires_pay_per_session'; end if;
  select coalesce(currency,'EUR') into v_currency from organizations where id=v_org;
  v_key:=coalesce(nullif(trim(coalesce(p_idempotency_key,'')),''),
    'balance:'||p_operation||':'||gen_random_uuid()::text);
  perform pg_advisory_xact_lock(hashtext(v_org::text||'|'||v_key));
  select e.id into v_entry from client_balance_entries e
    left join payments p on p.id=e.payment_id and p.org_id=e.org_id
    where e.org_id=v_org and (e.idempotency_key=v_key or p.idempotency_key=v_key)
    limit 1;
  if found then
    select coalesce(sum(amount),0) into v_balance from client_balance_entries
      where org_id=v_org and user_id=p_user_id;
    return jsonb_build_object('entry_id',v_entry,'balance',v_balance,'idempotent',true);
  end if;
  if p_operation='debt' then
    v_signed:=-round(p_amount,2); v_kind:='manual_debt';
    insert into client_balance_entries(org_id,user_id,kind,amount,note,effective_at,
      created_by,idempotency_key)
    values(v_org,p_user_id,v_kind,v_signed,nullif(trim(coalesce(p_note,'')),''),now(),auth.uid(),v_key)
    returning id into v_entry;
  elsif p_method='gratuito' then
    v_signed:=round(p_amount,2); v_kind:='manual_credit';
    insert into client_balance_entries(org_id,user_id,kind,amount,note,effective_at,
      created_by,idempotency_key)
    values(v_org,p_user_id,v_kind,v_signed,coalesce(nullif(trim(coalesce(p_note,'')),''),'Credito omaggio'),
      now(),auth.uid(),v_key) returning id into v_entry;
  else
    insert into payments(org_id,client_user_id,client_email,amount,currency,method,kind,
      note,created_by,idempotency_key)
    values(v_org,p_user_id,v_email,round(p_amount,2),v_currency,p_method,'account_credit',
      nullif(trim(coalesce(p_note,'')),''),auth.uid(),v_key) returning id into v_payment;
    select id into v_entry from client_balance_entries where payment_id=v_payment;
  end if;
  insert into admin_audit_log(org_id,actor_user_id,action,target_type,target_id,metadata)
  values(v_org,auth.uid(),'client_balance_'||p_operation,'profile',p_user_id::text,
    jsonb_build_object('amount',p_amount,'method',p_method,'entry_id',v_entry,'payment_id',v_payment));
  select coalesce(sum(amount),0) into v_balance from client_balance_entries
    where org_id=v_org and user_id=p_user_id;
  return jsonb_build_object('entry_id',v_entry,'payment_id',v_payment,'balance',v_balance,'idempotent',false);
end;
$$;
revoke all on function admin_record_client_balance_operation(uuid,text,numeric,text,text,text) from public,anon;
grant execute on function admin_record_client_balance_operation(uuid,text,numeric,text,text,text) to authenticated;

-- Al cambio del modello predefinito chiude i saldi operativi con una rettifica
-- esplicita. Lo storico resta intatto e continua a essere auditabile.
create or replace function reset_client_balances_after_default_model_change()
returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if old.default_model is not distinct from new.default_model then return new; end if;
  insert into client_balance_entries(org_id,user_id,kind,amount,note,effective_at,
    created_by,idempotency_key)
  select old.org_id,p.id,'model_reset',-coalesce(sum(e.amount),0),
    'Azzeramento saldo per cambio modello da '||old.default_model||' a '||new.default_model,
    now(),auth.uid(),'model-reset:'||txid_current()::text||':'||p.id::text
  from profiles p join client_balance_entries e
    on e.org_id=p.org_id and e.user_id=p.id
  where p.org_id=old.org_id
  group by p.id having coalesce(sum(e.amount),0)<>0
  on conflict (org_id,idempotency_key) do nothing;
  return new;
end;
$$;
revoke all on function reset_client_balances_after_default_model_change() from public,anon,authenticated;

drop trigger if exists reset_client_balances_after_default_model_change on billing_settings;
create trigger reset_client_balances_after_default_model_change
  after update of default_model on billing_settings for each row
  execute function reset_client_balances_after_default_model_change();

create or replace function get_client_balance_overview()
returns table(user_id uuid,name text,email text,whatsapp text,balance numeric,
  debt numeric,credit numeric,last_movement_at timestamptz)
language plpgsql security definer set search_path=public as $$
declare v_org uuid:=current_org_id();
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  perform process_due_session_balance_entries(v_org,10000);
  return query
  select p.id,p.name,p.email,p.whatsapp,
    round(coalesce(sum(e.amount),0),2),greatest(-round(coalesce(sum(e.amount),0),2),0),
    greatest(round(coalesce(sum(e.amount),0),2),0),max(e.effective_at)
  from profiles p
  join billing_settings bs on bs.org_id=p.org_id
  left join client_billing_profiles cbp on cbp.org_id=p.org_id and cbp.user_id=p.id
  left join client_balance_entries e on e.org_id=p.org_id and e.user_id=p.id
  where p.org_id=v_org and p.archived_at is null
    and coalesce(cbp.model_override,bs.default_model,'pay_per_session')='pay_per_session'
  group by p.id,p.name,p.email,p.whatsapp
  order by greatest(-coalesce(sum(e.amount),0),0) desc,p.name;
end;
$$;
revoke all on function get_client_balance_overview() from public,anon;
grant execute on function get_client_balance_overview() to authenticated;

create or replace function get_my_client_billing_status()
returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org uuid:=current_org_id(); v_user uuid:=auth.uid(); v_model text;
  v_balance numeric:=0; v_scheduled numeric:=0; v_count integer:=0;
begin
  if v_user is null or not exists(select 1 from profiles where id=v_user and org_id=v_org) then
    raise exception 'client_not_found';
  end if;
  perform process_due_session_balance_entries(v_org,10000);
  select coalesce(cbp.model_override,bs.default_model,'pay_per_session') into v_model
    from billing_settings bs left join client_billing_profiles cbp
      on cbp.org_id=bs.org_id and cbp.user_id=v_user where bs.org_id=v_org;
  select coalesce(sum(amount),0) into v_balance from client_balance_entries
    where org_id=v_org and user_id=v_user;
  if v_model='pay_per_session' then
    select coalesce(sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type),0)),0),count(*)
      into v_scheduled,v_count from bookings b join organizations o on o.id=b.org_id
      where b.org_id=v_org and b.user_id=v_user and b.billing_model_snapshot='pay_per_session'
        and b.billing_voided_at is null and b.status in ('confirmed','cancellation_requested')
        and ((b.date+split_part(b.time,' - ',1)::time)
          at time zone coalesce(o.timezone,'Europe/Rome'))>now();
  end if;
  return jsonb_build_object('model',v_model,'balance',round(v_balance,2),
    'credit',greatest(round(v_balance,2),0),'debt',greatest(-round(v_balance,2),0),
    'scheduled',round(v_scheduled,2),'scheduled_count',v_count);
end;
$$;
revoke all on function get_my_client_billing_status() from public,anon;
grant execute on function get_my_client_billing_status() to authenticated;

-- Il gating di prenotazione usa il debito reale del conto, non la vecchia
-- somma delle prenotazioni non pagate. Il resto conserva lock/capienza e consumo
-- di pacchetti/membership della versione hardenizzata.
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
    select coalesce((select cbp.model_override from client_billing_profiles cbp
      where cbp.org_id=v_org and cbp.user_id=v_book_user),
      (select bs.default_model from billing_settings bs where bs.org_id=v_org),'pay_per_session'),
      coalesce((select bs.grace_days from billing_settings bs where bs.org_id=v_org),0),
      coalesce((select bs.block_unpaid_threshold from billing_settings bs where bs.org_id=v_org),0)
      into v_model,v_grace,v_threshold;
    if v_model='free' then v_paid:=true; v_method:='gratuito';
    elsif v_model='package' then
      select * into v_pkg from client_packages where org_id=v_org and user_id=v_book_user
        and status='active' and remaining_sessions>0 and (expires_at is null or expires_at>=p_date::date)
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
    consumed_package_id,consumed_membership_id)
  values(v_org,p_local_id,v_book_user,p_date::date,p_time,v_cfg.slot_type,v_cfg.slot_type_id,
    trim(p_name),nullif(v_email,''),nullif(trim(coalesce(p_whatsapp,'')),''),p_notes,'confirmed',
    now(),p_date_display,v_uid,v_paid,v_method,case when v_paid then now() else null end,
    v_pkg_id,v_mem_id) returning id into v_id;
  return jsonb_build_object('success',true,'booking_id',v_id::text,'paid',v_paid);
exception when invalid_text_representation or datetime_field_overflow then
  return jsonb_build_object('success',false,'error','invalid_date_or_time');
end;
$$;
revoke all on function book_slot from public;
grant execute on function book_slot to anon,authenticated;

-- Summary amministrativa compatibile con i client esistenti, ma con credito e
-- debito derivati dal conto firmato (le lezioni future restano solo previsione).
create or replace function get_client_financial_summary(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_org uuid:=current_org_id(); v_result jsonb; v_model text;
  v_balance numeric:=0; v_future numeric:=0; v_future_count integer:=0;
begin
  if not (is_org_admin(v_org) or is_org_staff(v_org)) then raise exception 'unauthorized'; end if;
  if not exists(select 1 from profiles where id=p_user_id and org_id=v_org) then raise exception 'client_not_found'; end if;
  perform process_due_session_balance_entries(v_org,10000);
  select coalesce(cbp.model_override,bs.default_model,'pay_per_session') into v_model
    from billing_settings bs left join client_billing_profiles cbp
      on cbp.org_id=bs.org_id and cbp.user_id=p_user_id where bs.org_id=v_org;
  v_model:=coalesce(v_model,'pay_per_session');
  select coalesce(sum(amount),0) into v_balance from client_balance_entries
    where org_id=v_org and user_id=p_user_id;
  if v_model='pay_per_session' then
    select coalesce(sum(coalesce(b.custom_price,get_org_price(v_org,b.slot_type),0)),0),count(*)
      into v_future,v_future_count from bookings b join organizations o on o.id=b.org_id
      where b.org_id=v_org and b.user_id=p_user_id and b.billing_model_snapshot='pay_per_session'
        and b.billing_voided_at is null and b.status in ('confirmed','cancellation_requested')
        and ((b.date+split_part(b.time,' - ',1)::time)
          at time zone coalesce(o.timezone,'Europe/Rome'))>now();
  end if;
  select jsonb_build_object(
    'billing_profile',coalesce((select to_jsonb(x) from (select v_model model,
      coalesce(cbp.membership_period_override,bs.default_membership_period,'monthly') membership_period,
      cbp.custom_price,cbp.notes from billing_settings bs left join client_billing_profiles cbp
        on cbp.org_id=bs.org_id and cbp.user_id=p_user_id where bs.org_id=v_org) x),
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
    'balance_entries',coalesce((select jsonb_agg(to_jsonb(x) order by x.effective_at desc) from (
      select id,booking_id,payment_id,kind,amount,note,effective_at,created_at
      from client_balance_entries where org_id=v_org and user_id=p_user_id
      order by effective_at desc limit 100) x),'[]'::jsonb),
    'totals',jsonb_build_object(
      'collected',coalesce((select sum(amount) from payments where org_id=v_org and client_user_id=p_user_id),0),
      'balance',round(v_balance,2),'credit',greatest(round(v_balance,2),0),
      'debt',greatest(-round(v_balance,2),0),'unpaid',greatest(-round(v_balance,2),0),
      'unpaid_count',case when v_balance<0 then 1 else 0 end,
      'scheduled',round(v_future,2),'credit_count',v_future_count),
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
          and (expires_at is null or expires_at>=current_date)) when v_model='monthly'
        then not exists(select 1 from client_memberships where org_id=v_org and user_id=p_user_id
          and status='active' and period_start<=current_date
          and period_end>=current_date-make_interval(days=>coalesce(
            (select grace_days from billing_settings where org_id=v_org),0))
          and (lessons_quota is null or lessons_used<lessons_quota)) else false end,
      'unpaid_over_threshold',v_model='pay_per_session' and greatest(-v_balance,0)>
        coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)
        and coalesce((select block_unpaid_threshold from billing_settings where org_id=v_org),0)>0)
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function get_client_financial_summary(uuid) from public,anon;
grant execute on function get_client_financial_summary(uuid) to authenticated;

-- Esecuzione server-authoritative ogni minuto. Il richiamo nelle RPC copre
-- anche ambienti locali nei quali pg_cron non e disponibile/attivo.
create extension if not exists pg_cron;
do $$
declare v_job bigint;
begin
  for v_job in select jobid from cron.job where jobname='palestria-charge-lessons-at-start' loop
    perform cron.unschedule(v_job);
  end loop;
  perform cron.schedule('palestria-charge-lessons-at-start','* * * * *',
    $cron$select public.process_due_session_balance_entries(null,10000);$cron$);
end;
$$;
