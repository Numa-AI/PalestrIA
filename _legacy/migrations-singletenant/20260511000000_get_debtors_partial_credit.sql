-- Fix get_debtors: sottrae credit_applied dal debito residuo per booking.

create or replace function get_debtors(
    p_slot_prices jsonb default '{"personal-training":5,"small-group":10,"group-class":30,"cleaning":0}'
)
returns jsonb language plpgsql security definer
set search_path = public
set timezone = 'Europe/Rome' as $$
declare
    v_result jsonb;
begin
    if not is_admin() then
        raise exception 'Accesso negato: richiesto ruolo admin';
    end if;

    with
    unpaid as (
        select
            b.id,
            b.date::text                          as date,
            b.time,
            b.slot_type                           as "slotType",
            b.name,
            b.email,
            b.whatsapp,
            b.status,
            b.paid,
            b.notes,
            b.payment_method                      as "paymentMethod",
            b.paid_at                             as "paidAt",
            coalesce(b.credit_applied, 0)         as "creditApplied",
            coalesce((p_slot_prices ->> b.slot_type)::numeric, 0) as price,
            lower(b.email)                        as norm_email,
            normalize_phone(b.whatsapp)           as norm_phone
        from bookings b
        where b.paid = false
          and b.status <> 'cancelled'
          and (
              b.date < current_date
              or (
                  b.date = current_date
                  and (b.date + (split_part(b.time, ' - ', 1) || ':00')::time) <= now()
              )
          )
    ),
    phone_groups as (
        select norm_phone, min(norm_email) as canon_email
        from unpaid
        where norm_phone <> ''
        group by norm_phone
    ),
    email_groups as (
        select u.norm_email,
            least(u.norm_email, coalesce(min(pg.canon_email), u.norm_email)) as canon_email
        from unpaid u
        left join phone_groups pg on u.norm_phone = pg.norm_phone and u.norm_phone <> ''
        group by u.norm_email
    ),
    resolved as (
        select eg.norm_email,
            least(eg.canon_email, coalesce(min(eg2.canon_email), eg.canon_email)) as ckey
        from email_groups eg
        left join phone_groups pg on pg.canon_email = eg.norm_email
        left join email_groups eg2 on eg2.norm_email = (
            select min(u2.norm_email)
            from unpaid u2
            where u2.norm_phone = pg.norm_phone and u2.norm_phone <> ''
        )
        group by eg.norm_email, eg.canon_email
    ),
    keyed as (
        select u.*, coalesce(r.ckey, u.norm_email) as ckey
        from unpaid u
        left join resolved r on u.norm_email = r.norm_email
    ),
    grouped as (
        select
            ckey,
            (array_agg(name order by date asc, time asc))[1]      as name,
            (array_agg(whatsapp order by date asc, time asc))[1]  as whatsapp,
            (array_agg(email order by date asc, time asc))[1]     as email,
            sum(price - "creditApplied")                          as booking_debt,
            jsonb_agg(
                jsonb_build_object(
                    'id',            id,
                    'date',          date,
                    'time',          time,
                    'slotType',      "slotType",
                    'name',          name,
                    'email',         email,
                    'whatsapp',      whatsapp,
                    'status',        status,
                    'paid',          paid,
                    'notes',         notes,
                    'paymentMethod', "paymentMethod",
                    'paidAt',        "paidAt",
                    'creditApplied', "creditApplied",
                    'price',         price,
                    'displayPrice',  price - "creditApplied"
                )
                order by date desc, time desc
            ) as "unpaidBookings"
        from keyed
        group by ckey
    ),
    with_debts as (
        select g.*, coalesce(md.balance, 0) as manual_debt, coalesce(md.history, '[]'::jsonb) as manual_debt_history
        from grouped g
        left join manual_debts md on lower(md.email) = g.ckey
    ),
    with_credits as (
        select wd.*,
            round((wd.booking_debt + wd.manual_debt - coalesce(cr.balance, 0))::numeric, 2) as total_amount
        from with_debts wd
        left join credits cr on lower(cr.email) = wd.ckey
    )
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'name',              name,
                'whatsapp',          whatsapp,
                'email',             email,
                'unpaidBookings',    "unpaidBookings",
                'manualDebt',        manual_debt,
                'manualDebtHistory', manual_debt_history,
                'totalAmount',       total_amount
            )
            order by total_amount desc
        ),
        '[]'::jsonb
    )
    into v_result
    from with_credits
    where total_amount > 0;

    return v_result;
end;
$$;

revoke all on function get_debtors(jsonb) from public;
grant execute on function get_debtors(jsonb) to authenticated;
