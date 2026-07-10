-- Snapshot the per-client agreed price on each pay-per-session booking.

create or replace function apply_client_booking_price()
returns trigger
language plpgsql security definer set search_path=public as $$
declare v_price numeric;
begin
  if new.user_id is null or new.custom_price is not null then return new; end if;
  select cbp.custom_price into v_price
    from client_billing_profiles cbp
    where cbp.org_id=new.org_id and cbp.user_id=new.user_id
      and cbp.model_override='pay_per_session';
  if v_price is not null then new.custom_price:=v_price; end if;
  return new;
end;
$$;
revoke all on function apply_client_booking_price() from public,anon,authenticated;

drop trigger if exists apply_client_booking_price_before_insert on bookings;
create trigger apply_client_booking_price_before_insert
  before insert on bookings for each row execute function apply_client_booking_price();
