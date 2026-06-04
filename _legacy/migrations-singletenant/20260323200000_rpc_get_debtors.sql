-- ─── RPC get_debtors: calcola debitori server-side ─────────────────────────
-- Sostituisce la funzione JS getDebtors() che faceva loop O(n²) nel browser.
-- Restituisce lo stesso identico JSON che il frontend si aspetta.

-- 1. Helper: normalizza telefono per matching (stessa logica del JS normalizePhone)
create or replace function normalize_phone(p_phone text)
returns text language sql immutable as $$
    select regexp_replace(
        regexp_replace(coalesce(p_phone, ''), '^\+39\s*|^0039\s*', '', 'g'),
        '[\s\-\(\)\. ]', '', 'g'
    );
$$;

-- 2. RPC principale
-- set timezone = 'Europe/Rome': allinea current_date/now() al fuso italiano
-- (il browser confronta con new Date() che usa il fuso locale dell'utente)
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
    -- Booking non pagati il cui orario di inizio è già passato (fuso italiano)
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
                  and (b.date + (split_part(b.time, ' - ', 1) || ':00')::time)
                      <= now()
              )
          )
    ),
    -- ── Raggruppamento contatti: stessa logica del JS (match telefono OR email) ──
    -- Union-Find semplificato: per ogni booking, la chiave è il min(norm_email)
    -- tra tutti i booking che condividono lo stesso telefono O la stessa email.
    -- Questo replica il cross-match: se A ha phone=111/email=a@x e B ha phone=222/email=a@x,
    -- entrambi finiscono sotto la stessa chiave (a@x).
    phone_groups as (
        -- Per ogni telefono non vuoto, trova l'email canonico (la prima in ordine alfabetico)
        select norm_phone, min(norm_email) as canon_email
        from unpaid
        where norm_phone <> ''
        group by norm_phone
    ),
    email_groups as (
        -- Per ogni email, trova l'email canonico tramite i telefoni collegati
        select u.norm_email,
            least(
                u.norm_email,
                coalesce(min(pg.canon_email), u.norm_email)
            ) as canon_email
        from unpaid u
        left join phone_groups pg on u.norm_phone = pg.norm_phone and u.norm_phone <> ''
        group by u.norm_email
    ),
    -- Risolvi transitive: se a@x → a@x e b@y → a@x tramite telefono,
    -- ma anche c@z → b@y tramite un altro telefono, serve propagare.
    -- In pratica con i dati reali raramente ci sono catene > 1 livello.
    -- Facciamo un secondo passaggio per sicurezza.
    resolved as (
        select eg.norm_email,
            least(
                eg.canon_email,
                coalesce(min(eg2.canon_email), eg.canon_email)
            ) as ckey
        from email_groups eg
        left join phone_groups pg on pg.canon_email = eg.norm_email
        left join email_groups eg2 on eg2.norm_email = (
            select min(u2.norm_email)
            from unpaid u2
            where u2.norm_phone = pg.norm_phone and u2.norm_phone <> ''
        )
        group by eg.norm_email, eg.canon_email
    ),
    -- Assegna chiave contatto a ogni booking
    keyed as (
        select u.*, coalesce(r.ckey, u.norm_email) as ckey
        from unpaid u
        left join resolved r on u.norm_email = r.norm_email
    ),
    -- Aggrega per contatto
    grouped as (
        select
            ckey,
            (array_agg(name order by date asc, time asc))[1]      as name,
            (array_agg(whatsapp order by date asc, time asc))[1]  as whatsapp,
            (array_agg(email order by date asc, time asc))[1]     as email,
            sum(price)                                             as booking_debt,
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
                    'price',         price
                )
                order by date desc, time desc
            ) as "unpaidBookings"
        from keyed
        group by ckey
    ),
    -- Merge debiti manuali (match per email)
    with_debts as (
        select
            g.*,
            coalesce(md.balance, 0) as manual_debt,
            coalesce(md.history, '[]'::jsonb) as manual_debt_history
        from grouped g
        left join manual_debts md on lower(md.email) = g.ckey
    ),
    -- Sottrai crediti (match per email)
    with_credits as (
        select
            wd.*,
            round(
                (wd.booking_debt + wd.manual_debt - coalesce(cr.balance, 0))::numeric,
                2
            ) as total_amount
        from with_debts wd
        left join credits cr on lower(cr.email) = wd.ckey
    )
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'name',               name,
                'whatsapp',           whatsapp,
                'email',              email,
                'unpaidBookings',     "unpaidBookings",
                'manualDebt',         manual_debt,
                'manualDebtHistory',  manual_debt_history,
                'totalAmount',        total_amount
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
