-- ─────────────────────────────────────────────────────────────────────────────
-- Migration incrementale — fix dall'audit codice multi-agente (2026-06-09)
-- ─────────────────────────────────────────────────────────────────────────────
-- Le stesse modifiche sono già nei file baseline/operational_rpcs (consolidati),
-- ma quei file risultano GIÀ APPLICATI nello storico migration del progetto remoto,
-- quindi `supabase db push` li salta ("Remote database is up to date"). Questa
-- migration porta in produzione, in modo idempotente, le sole modifiche SQL:
--   1) colonne bookings.consumed_package_id / consumed_membership_id (refund)
--   2) book_slot            → popola le colonne consumed_* al decremento
--   3) admin_pay_bookings   → 'gratuito' = importo 0 (no incasso fittizio)
--   4) cancel_booking       → refund pacchetto/membership + cutoff non-admin
--   5) admin_delete_booking → refund pacchetto/membership prima del delete
-- ─────────────────────────────────────────────────────────────────────────────

-- 1) Colonne per il refund deterministico (uuid "soft", no FK: il refund gestisce
--    comunque le righe eventualmente rimosse). idempotente.
alter table bookings add column if not exists consumed_package_id    uuid;
alter table bookings add column if not exists consumed_membership_id uuid;

-- 2) book_slot — traccia il pacchetto/membership consumato (v_pkg_id/v_mem_id) e lo
--    salva sul booking, per poterlo restituire in cancellazione.
create or replace function book_slot(
    p_org_slug   text,
    p_local_id   text,
    p_date       text,
    p_time       text,
    p_name       text,
    p_email      text,
    p_whatsapp   text,
    p_notes      text,
    p_date_display text default '',
    p_for_user_id uuid default null   -- admin: prenota per conto di un cliente
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org        uuid;
    v_uid        uuid := auth.uid();
    v_book_user  uuid;
    v_email      text := lower(trim(coalesce(p_email, '')));
    v_cfg        record;
    v_count      integer;
    v_id         uuid;
    v_is_admin   boolean := false;
    v_start_time time;
    v_lesson_dt  timestamptz;
    v_tz         text;
    v_model      text;
    v_pkg        client_packages%rowtype;
    v_mem        client_memberships%rowtype;
    v_pkg_id     uuid := null;   -- pacchetto effettivamente decrementato (per refund su cancel)
    v_mem_id     uuid := null;   -- membership la cui quota è stata consumata (per refund su cancel)
    v_paid       boolean := false;
    v_method     text := null;
begin
    -- risolvi org: slug (anon/pubblico) oppure org del chiamante
    v_org := coalesce(org_id_for_slug(p_org_slug), current_org_id());
    if v_org is null then
        return jsonb_build_object('success', false, 'error', 'org_not_found');
    end if;
    v_is_admin := is_org_admin(v_org);
    select timezone into v_tz from organizations where id = v_org;
    v_tz := coalesce(v_tz, 'Europe/Rome');

    -- A chi attribuire il booking (bookings.user_id → profiles, può essere NULL):
    --  - admin che prenota per un cliente (p_for_user_id, deve essere profilo della org)
    --  - altrimenti il chiamante, se è un profilo cliente della org
    --  - altrimenti NULL (anonimo, o admin/staff senza profilo cliente → niente FK error)
    if p_for_user_id is not null and v_is_admin
       and exists (select 1 from profiles where id = p_for_user_id and org_id = v_org) then
        v_book_user := p_for_user_id;
    elsif v_uid is not null
       and exists (select 1 from profiles where id = v_uid and org_id = v_org) then
        v_book_user := v_uid;
    else
        v_book_user := null;
    end if;

    if v_email <> '' and v_email !~ '^[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' then
        return jsonb_build_object('success', false, 'error', 'invalid_email');
    end if;
    if p_name is null or trim(p_name) = '' then
        return jsonb_build_object('success', false, 'error', 'missing_name');
    end if;
    if p_date::date < current_date and not v_is_admin then
        return jsonb_build_object('success', false, 'error', 'past_date');
    end if;

    -- config slot (capienza/prezzo) server-side
    select * into v_cfg from resolve_slot_config(v_org, p_date::date, p_time);
    if not coalesce(v_cfg.bookable, false) or coalesce(v_cfg.capacity, 0) <= 0 then
        return jsonb_build_object('success', false, 'error', 'not_bookable');
    end if;

    -- cutoff troppo tardi (solo non-admin)
    if not v_is_admin then
        v_start_time := split_part(p_time, ' - ', 1)::time;
        v_lesson_dt  := (p_date::date + v_start_time) at time zone v_tz;
        if now() > v_lesson_dt + interval '30 minutes' then
            return jsonb_build_object('success', false, 'error', 'too_late');
        end if;
    end if;

    -- advisory lock anti-overbooking (include org_id)
    if not pg_try_advisory_xact_lock(hashtext(v_org::text || '|' || p_date || '|' || p_time || '|' || v_cfg.slot_type)) then
        return jsonb_build_object('success', false, 'error', 'slot_busy');
    end if;

    select count(*) into v_count from bookings
        where org_id = v_org and date = p_date::date and time = p_time
          and slot_type = v_cfg.slot_type
          and status in ('confirmed','cancellation_requested');
    if v_count >= v_cfg.capacity then
        return jsonb_build_object('success', false, 'error', 'slot_full');
    end if;

    -- gating/decremento billing-cliente (solo se cliente identificato)
    if v_book_user is not null then
        select coalesce(cbp.model_override, bs.default_model, 'pay_per_session')
            into v_model
            from billing_settings bs
            left join client_billing_profiles cbp
                   on cbp.org_id = v_org and cbp.user_id = v_book_user
            where bs.org_id = v_org;
        v_model := coalesce(v_model, 'pay_per_session');

        if v_model = 'free' then
            v_paid := true; v_method := 'gratuito';
        elsif v_model = 'package' then
            select * into v_pkg from client_packages
                where org_id = v_org and user_id = v_book_user and status = 'active'
                  and remaining_sessions > 0 and (expires_at is null or expires_at >= current_date)
                order by purchased_at asc limit 1 for update;
            if not found then
                if (select block_if_no_package from billing_settings where org_id = v_org) then
                    return jsonb_build_object('success', false, 'error', 'no_package');
                end if;
            else
                update client_packages set remaining_sessions = remaining_sessions - 1,
                    status = case when remaining_sessions - 1 <= 0 then 'exhausted' else status end
                    where id = v_pkg.id;
                v_pkg_id := v_pkg.id;
                v_paid := true; v_method := 'pacchetto';
            end if;
        elsif v_model = 'monthly' then
            select * into v_mem from client_memberships
                where org_id = v_org and user_id = v_book_user and status = 'active'
                order by period_end desc limit 1 for update;
            if not found or v_mem.period_end < (current_date - make_interval(days => coalesce((select grace_days from billing_settings where org_id = v_org),0))) then
                if (select block_if_membership_expired from billing_settings where org_id = v_org) then
                    return jsonb_build_object('success', false, 'error', 'membership_expired');
                end if;
            elsif v_mem.lessons_quota is not null and v_mem.lessons_used >= v_mem.lessons_quota then
                return jsonb_build_object('success', false, 'error', 'quota_exceeded');
            else
                update client_memberships set lessons_used = lessons_used + 1 where id = v_mem.id;
                v_mem_id := v_mem.id;
                v_paid := true; v_method := 'abbonamento';
            end if;
        end if;
        -- pay_per_session: paid=false, saldo via admin_pay_bookings
    end if;

    insert into bookings (org_id, local_id, user_id, date, time, slot_type, slot_type_id,
        name, email, whatsapp, notes, status, created_at, date_display, created_by,
        paid, payment_method, paid_at, consumed_package_id, consumed_membership_id)
    values (v_org, p_local_id, v_book_user, p_date::date, p_time, v_cfg.slot_type, v_cfg.slot_type_id,
        trim(p_name), nullif(v_email,''), nullif(trim(coalesce(p_whatsapp,'')),''), p_notes,
        'confirmed', now(), p_date_display, v_uid,
        v_paid, v_method, case when v_paid then now() else null end, v_pkg_id, v_mem_id)
    returning id into v_id;

    return jsonb_build_object('success', true, 'booking_id', v_id::text, 'paid', v_paid);
exception
    when unique_violation then
        return jsonb_build_object('success', false, 'error', 'duplicate_booking');
end;
$$;
revoke all on function book_slot from public;
grant execute on function book_slot to anon, authenticated;

-- 3) admin_pay_bookings — lezione 'gratuito' → importo 0 nel ledger (no incasso fittizio).
create or replace function admin_pay_bookings(
    p_booking_ids uuid[],
    p_method      text,
    p_paid_at     timestamptz default now()
) returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_org   uuid := current_org_id();
    v_b     bookings%rowtype;
    v_price numeric(10,2);
    v_count integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;

    for v_b in select * from bookings
        where id = any(p_booking_ids) and org_id = v_org for update
    loop
        update bookings set paid = true, payment_method = p_method, paid_at = p_paid_at
            where id = v_b.id and not paid;
        if found then
            -- Lezione regalata: importo 0 e metodo 'gratuito' (escluso dal fatturato in
            -- admin-analytics). Senza questo ramo cadrebbe in 'contanti' a prezzo pieno,
            -- gonfiando l'incasso con denaro mai ricevuto.
            v_price := case when p_method = 'gratuito'
                            then 0
                            else coalesce(v_b.custom_price, get_org_price(v_org, v_b.slot_type)) end;
            insert into payments (org_id, client_user_id, client_email, amount, currency,
                method, kind, booking_id, created_by)
            values (v_org, v_b.user_id, v_b.email, v_price,
                (select currency from organizations where id = v_org),
                case when p_method in ('contanti','contanti-report','carta','iban','stripe','gratuito') then p_method else 'contanti' end,
                'session', v_b.id, auth.uid())
            on conflict (booking_id) where kind = 'session' do nothing;
            v_count := v_count + 1;
        end if;
    end loop;
    return v_count;
end;
$$;
revoke all on function admin_pay_bookings from public;
grant execute on function admin_pay_bookings to authenticated;

-- 4) admin_delete_booking — refund della sessione/quota consumata prima del delete.
create or replace function admin_delete_booking(p_booking_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_org     uuid := current_org_id();
    v_booking record;
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;

    select * into v_booking from bookings
        where id = p_booking_id and org_id = v_org for update;

    if found then
        -- Restituisce la sessione/quota consumata (solo se non già cancellata:
        -- una prenotazione 'cancelled' ha già ricevuto il refund in cancel_booking).
        if v_booking.status <> 'cancelled' then
            if v_booking.consumed_package_id is not null then
                update client_packages
                    set remaining_sessions = remaining_sessions + 1,
                        status = case when status = 'exhausted' then 'active' else status end
                    where id = v_booking.consumed_package_id and org_id = v_org;
            elsif v_booking.consumed_membership_id is not null then
                update client_memberships
                    set lessons_used = greatest(lessons_used - 1, 0)
                    where id = v_booking.consumed_membership_id and org_id = v_org;
            end if;
        end if;
    end if;

    delete from bookings where id = p_booking_id and org_id = v_org;
end;
$$;
revoke all on function admin_delete_booking(uuid) from public;
grant execute on function admin_delete_booking(uuid) to authenticated;

-- 5) cancel_booking — refund pacchetto/membership + cutoff temporale per i non-admin.
create or replace function cancel_booking(p_booking_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org      uuid := current_org_id();
    v_booking  record;
    v_st_small uuid;
    v_is_admin boolean := is_org_admin(v_org);
    v_tz       text;
    v_start    time;
    v_lesson   timestamptz;
begin
    select * into v_booking
    from bookings
    where id = p_booking_id and org_id = v_org
    for update;

    if not found then
        return jsonb_build_object('success', false, 'error', 'booking_not_found');
    end if;

    -- autorizzazione: proprietario o admin
    if v_booking.user_id is distinct from auth.uid() and not v_is_admin then
        return jsonb_build_object('success', false, 'error', 'unauthorized');
    end if;

    if v_booking.status = 'cancelled' then
        return jsonb_build_object('success', false, 'error', 'already_cancelled');
    end if;

    -- Cutoff lato server per i NON-admin: la policy mostrata in UI (prenotazioni.html)
    -- va applicata anche qui, altrimenti è aggirabile chiamando la RPC direttamente
    -- (disdetta all'ultimo, o estinzione di un debito pay-per-session cancellando la
    --  lezione passata). Grace 10 min dalla creazione → sempre annullabile; altrimenti
    --  group-class > 3 giorni, altri tipi > 24h dall'inizio lezione (timezone della org).
    if not v_is_admin then
        select timezone into v_tz from organizations where id = v_org;
        v_tz := coalesce(v_tz, 'Europe/Rome');
        v_start  := split_part(v_booking.time, ' - ', 1)::time;
        v_lesson := (v_booking.date + v_start) at time zone v_tz;
        if now() - v_booking.created_at >= interval '10 minutes' then
            if v_booking.slot_type = 'group-class' then
                if v_lesson <= now() + interval '3 days' then
                    return jsonb_build_object('success', false, 'error', 'cancellation_window_closed');
                end if;
            else
                if v_lesson <= now() + interval '24 hours' then
                    return jsonb_build_object('success', false, 'error', 'cancellation_window_closed');
                end if;
            end if;
        end if;
    end if;

    -- Refund: restituisce la sessione del pacchetto / la quota della membership
    -- effettivamente consumata da questa prenotazione (tracciata in book_slot).
    if v_booking.consumed_package_id is not null then
        update client_packages
            set remaining_sessions = remaining_sessions + 1,
                status = case when status = 'exhausted' then 'active' else status end
            where id = v_booking.consumed_package_id and org_id = v_org;
    elsif v_booking.consumed_membership_id is not null then
        update client_memberships
            set lessons_used = greatest(lessons_used - 1, 0)
            where id = v_booking.consumed_membership_id and org_id = v_org;
    end if;

    -- cambio stato (niente credito/bonus/penale). Azzera i riferimenti consumati
    -- così un'eventuale ri-cancellazione non può applicare un secondo refund.
    update bookings set
        status                   = 'cancelled',
        cancelled_at             = now(),
        cancelled_by             = auth.uid(),
        cancelled_payment_method = v_booking.payment_method,
        cancelled_paid_at        = v_booking.paid_at,
        paid                     = false,
        payment_method           = null,
        paid_at                  = null,
        consumed_package_id      = null,
        consumed_membership_id   = null
    where id = p_booking_id and org_id = v_org;

    -- riconversione slot: una group-class annullata torna small-group
    -- (override puntuale per quella data/orario)
    if v_booking.slot_type = 'group-class' then
        select id into v_st_small
        from slot_types
        where org_id = v_org and key = 'small-group' and is_active
        limit 1;

        if v_st_small is not null then
            insert into schedule_overrides (org_id, date, time, slot_type, slot_type_id)
            values (v_org, v_booking.date, v_booking.time, 'small-group', v_st_small)
            on conflict (org_id, date, time)
            do update set slot_type = 'small-group', slot_type_id = v_st_small;
        end if;
    end if;

    return jsonb_build_object('success', true);
end;
$$;
revoke all on function cancel_booking(uuid) from public;
grant execute on function cancel_booking(uuid) to authenticated, service_role;
