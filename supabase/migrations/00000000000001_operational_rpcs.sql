-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — RPC operative org-scoped (post-baseline)
--
-- Porting delle RPC operative dalle vecchie migration single-tenant
-- (_legacy/migrations-singletenant/) adattate al modello multi-tenant pooled:
--   • filtro org_id sempre presente (current_org_id() per autenticati,
--     org_id_for_slug(p_org_slug) per pubbliche/anonime);
--   • ZERO logica credito/bonus/debito (sistema rimosso);
--   • firme canoniche del contratto RPC;
--   • prezzi/capienze server-authoritative (resolve_slot_config / get_org_price).
--
-- Tutte SECURITY DEFINER + set search_path = public + idempotenti (create or replace).
-- ══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO A — DISPONIBILITÀ (pubblica/anonima, scoped a org via slug)
-- ─────────────────────────────────────────────────────────────────────────────

-- Disponibilità su un range di date. Per ogni slot prenotato/configurato
-- restituisce capienza, prenotati confermati e posti residui.
-- Pubblica: solo aggregati, nessun dato personale. Porting di get_availability_range
-- (_legacy/.../20260310300000_bookings_privacy.sql) + capienza da resolve_slot_config.
create or replace function get_availability_range(p_org_slug text, p_from date, p_to date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
    v_org uuid := org_id_for_slug(p_org_slug);
begin
    if v_org is null then
        return '[]'::jsonb;
    end if;

    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'date',            agg.date,
            'time',            agg.time,
            'slot_type',       agg.slot_type,
            'capacity',        coalesce(cfg.capacity, 0),
            'confirmed_count', agg.confirmed_count,
            'remaining',       greatest(coalesce(cfg.capacity, 0) - agg.confirmed_count, 0)
        ))
        from (
            select b.date, b.time, b.slot_type, count(*)::int as confirmed_count
            from bookings b
            where b.org_id = v_org
              and b.date between p_from and p_to
              and b.status = 'confirmed'
            group by b.date, b.time, b.slot_type
        ) agg
        cross join lateral resolve_slot_config(v_org, agg.date, agg.time) cfg
    ), '[]'::jsonb);
end;
$$;
revoke all on function get_availability_range(text, date, date) from public;
grant execute on function get_availability_range(text, date, date) to anon, authenticated;

-- Disponibilità di una singola data (check rapido prima di prenotare).
-- Porting di get_slot_availability (_legacy/.../20260310300000_bookings_privacy.sql).
create or replace function get_slot_availability(p_org_slug text, p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
    v_org uuid := org_id_for_slug(p_org_slug);
begin
    if v_org is null then
        return '[]'::jsonb;
    end if;

    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'time',            agg.time,
            'slot_type',       agg.slot_type,
            'capacity',        coalesce(cfg.capacity, 0),
            'confirmed_count', agg.confirmed_count,
            'remaining',       greatest(coalesce(cfg.capacity, 0) - agg.confirmed_count, 0)
        ))
        from (
            select b.time, b.slot_type, count(*)::int as confirmed_count
            from bookings b
            where b.org_id = v_org
              and b.date = p_date
              and b.status = 'confirmed'
            group by b.time, b.slot_type
        ) agg
        cross join lateral resolve_slot_config(v_org, p_date, agg.time) cfg
    ), '[]'::jsonb);
end;
$$;
revoke all on function get_slot_availability(text, date) from public;
grant execute on function get_slot_availability(text, date) to anon, authenticated;

-- Nomi degli iscritti a uno slot (lista "persone iscritte" nel modal di prenotazione).
-- Chi ha profiles.privacy_prenotazioni = true compare come "Anonimo".
-- Porting di get_slot_attendees (_legacy/.../20260328000000_privacy_prenotazioni.sql),
-- ora filtrato per org via slug. Pubblica (serve anche prima del login).
create or replace function get_slot_attendees(p_org_slug text, p_date date, p_time text)
returns table(name text)
language sql stable security definer set search_path = public as $$
    select case when p.privacy_prenotazioni then 'Anonimo' else p.name end as name
    from   bookings b
    join   profiles p on p.id = b.user_id and p.org_id = b.org_id
    where  b.org_id = org_id_for_slug(p_org_slug)
      and  b.date   = p_date
      and  b.time   = p_time
      and  b.status = 'confirmed'
    order by case when p.privacy_prenotazioni then 1 else 0 end, p.name;
$$;
revoke all on function get_slot_attendees(text, date, text) from public;
grant execute on function get_slot_attendees(text, date, text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO B — PROFILI / REGISTRAZIONE
-- ─────────────────────────────────────────────────────────────────────────────

-- Elenco profili della propria org (solo org admin).
-- Porting di get_all_profiles (_legacy/.../20260314200000_restrict_get_all_profiles.sql
-- + 20260328000000_privacy_prenotazioni.sql), ora filtrato per current_org_id().
drop function if exists get_all_profiles();
create or replace function get_all_profiles()
returns table (
    id                   uuid,
    name                 text,
    email                text,
    whatsapp             text,
    medical_cert_expiry  text,
    medical_cert_history jsonb,
    insurance_expiry     text,
    insurance_history    jsonb,
    codice_fiscale       text,
    indirizzo_via        text,
    indirizzo_cap        text,
    indirizzo_paese      text,
    documento_firmato    boolean,
    geo_enabled          boolean,
    push_enabled         boolean,
    privacy_prenotazioni boolean
)
language plpgsql stable security definer set search_path = public as $$
declare
    v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;
    return query
        select p.id, p.name, p.email, p.whatsapp,
               p.medical_cert_expiry::text, p.medical_cert_history,
               p.insurance_expiry::text, p.insurance_history,
               p.codice_fiscale,
               p.indirizzo_via, p.indirizzo_cap, p.indirizzo_paese,
               p.documento_firmato, p.geo_enabled, p.push_enabled,
               p.privacy_prenotazioni
        from profiles p
        where p.org_id = v_org
        order by p.name;
end;
$$;
revoke all on function get_all_profiles() from public;
grant execute on function get_all_profiles() to authenticated;

-- Verifica se un numero WhatsApp è già in uso NELLA org corrente (registrazione/profilo).
-- Porting di is_whatsapp_taken (_legacy/.../20260312600000_unique_whatsapp.sql).
-- Scoped alla org corrente: org diverse possono avere lo stesso numero.
-- v_org via current_org_id() (autenticato) con fallback a JWT slug per i flussi di signup.
create or replace function is_whatsapp_taken(phone text, exclude_user_id uuid default null)
returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from profiles
        where org_id   = current_org_id()
          and whatsapp = phone
          and whatsapp is not null and whatsapp <> ''
          and (exclude_user_id is null or id <> exclude_user_id)
    );
$$;
revoke all on function is_whatsapp_taken(text, uuid) from public;
grant execute on function is_whatsapp_taken(text, uuid) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO C — GESTIONE BOOKING (admin)
-- ─────────────────────────────────────────────────────────────────────────────

-- Aggiornamento booking lato admin (bypassa RLS, org-scoped, optimistic locking).
-- Porting di admin_update_booking (_legacy/.../20260312900000_cancelled_refund_pct.sql),
-- RIMOSSI i parametri credito/bonus/penalty (p_credit_applied, p_cancelled_with_bonus,
-- p_cancelled_with_penalty). Mantenuti i campi non legati al credito.
drop function if exists admin_update_booking(uuid, text, boolean, text, timestamptz, numeric, timestamptz, timestamptz, text, timestamptz, boolean, boolean, integer, timestamptz);
create or replace function admin_update_booking(
    p_booking_id                uuid,
    p_status                    text,
    p_paid                      boolean      default false,
    p_payment_method            text         default null,
    p_paid_at                   timestamptz  default null,
    p_custom_price              numeric      default null,
    p_cancellation_requested_at timestamptz  default null,
    p_cancelled_at              timestamptz  default null,
    p_cancelled_payment_method  text         default null,
    p_cancelled_paid_at         timestamptz  default null,
    p_cancelled_refund_pct      integer      default null,
    p_arrived_at                timestamptz  default null,
    p_expected_updated_at       timestamptz  default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org     uuid := current_org_id();
    v_booking record;
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;

    select id, updated_at into v_booking
    from bookings
    where id = p_booking_id and org_id = v_org
    for update;

    if not found then
        return jsonb_build_object('success', false, 'error', 'booking_not_found');
    end if;

    -- optimistic locking: rifiuta se il record è stato modificato altrove
    if p_expected_updated_at is not null
       and v_booking.updated_at <> p_expected_updated_at then
        return jsonb_build_object(
            'success', false,
            'error',   'stale_data',
            'server_updated_at', v_booking.updated_at
        );
    end if;

    update bookings set
        status                    = p_status,
        paid                      = p_paid,
        payment_method            = p_payment_method,
        paid_at                   = p_paid_at,
        custom_price              = p_custom_price,
        cancellation_requested_at = p_cancellation_requested_at,
        cancelled_at              = p_cancelled_at,
        cancelled_payment_method  = p_cancelled_payment_method,
        cancelled_paid_at         = p_cancelled_paid_at,
        cancelled_refund_pct      = p_cancelled_refund_pct,
        arrived_at                = p_arrived_at
    where id = p_booking_id and org_id = v_org;

    return jsonb_build_object('success', true, 'updated_at', now());
end;
$$;
revoke all on function admin_update_booking(uuid, text, boolean, text, timestamptz, numeric, timestamptz, timestamptz, text, timestamptz, integer, timestamptz, timestamptz) from public;
grant execute on function admin_update_booking(uuid, text, boolean, text, timestamptz, numeric, timestamptz, timestamptz, text, timestamptz, integer, timestamptz, timestamptz) to authenticated;

-- Eliminazione fisica di un booking (solo org admin, org-scoped).
-- Porting di admin_delete_booking (_legacy/.../20260309200000_admin_delete_booking.sql),
-- SENZA rimborso credito (admin_delete_booking_with_refund eliminata).
create or replace function admin_delete_booking(p_booking_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;
    delete from bookings where id = p_booking_id and org_id = v_org;
end;
$$;
revoke all on function admin_delete_booking(uuid) from public;
grant execute on function admin_delete_booking(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO D — CANCELLAZIONI (utente / sistema)
-- ─────────────────────────────────────────────────────────────────────────────

-- Richiesta di annullamento da parte del cliente proprietario (o admin).
-- Setta status = 'cancellation_requested'. NESSUN rimborso credito.
-- Porting di user_request_cancellation (_legacy/.../20260327100000_track_actor.sql),
-- ora org-scoped via current_org_id().
create or replace function user_request_cancellation(p_booking_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org     uuid := current_org_id();
    v_booking record;
begin
    select * into v_booking
    from bookings
    where id = p_booking_id and org_id = v_org
    for update;

    if not found then
        return jsonb_build_object('success', false, 'error', 'booking_not_found');
    end if;

    -- solo il proprietario o un admin della org
    if v_booking.user_id is distinct from auth.uid() and not is_org_admin(v_org) then
        return jsonb_build_object('success', false, 'error', 'unauthorized');
    end if;

    if v_booking.status <> 'confirmed' then
        return jsonb_build_object('success', false, 'error', 'not_confirmed');
    end if;

    update bookings set
        status                    = 'cancellation_requested',
        cancellation_requested_at = now(),
        cancelled_by              = auth.uid()
    where id = p_booking_id and org_id = v_org;

    return jsonb_build_object('success', true);
end;
$$;
revoke all on function user_request_cancellation(uuid) from public;
grant execute on function user_request_cancellation(uuid) to authenticated, service_role;

-- Cancellazione effettiva di un booking (proprietario o admin).
-- Solo cambio stato a 'cancelled' + eventuale riconversione dello slot
-- group-class → small-group in schedule_overrides. NESSUN rimborso credito.
-- Porting della logica JS (data.js: "Converte lo slot ... da group-class a small-group"),
-- adattata e org-scoped.
create or replace function cancel_booking(p_booking_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org      uuid := current_org_id();
    v_booking  record;
    v_st_small uuid;
begin
    select * into v_booking
    from bookings
    where id = p_booking_id and org_id = v_org
    for update;

    if not found then
        return jsonb_build_object('success', false, 'error', 'booking_not_found');
    end if;

    -- autorizzazione: proprietario o admin
    if v_booking.user_id is distinct from auth.uid() and not is_org_admin(v_org) then
        return jsonb_build_object('success', false, 'error', 'unauthorized');
    end if;

    if v_booking.status = 'cancelled' then
        return jsonb_build_object('success', false, 'error', 'already_cancelled');
    end if;

    -- cambio stato (niente credito/bonus/penale)
    update bookings set
        status                   = 'cancelled',
        cancelled_at             = now(),
        cancelled_by             = auth.uid(),
        cancelled_payment_method = v_booking.payment_method,
        cancelled_paid_at        = v_booking.paid_at,
        paid                     = false,
        payment_method           = null,
        paid_at                  = null
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

-- Cron: ripristina a 'confirmed' le richieste di annullamento arrivate troppo tardi
-- (≤ 2 ore all'inizio della lezione). Tutte le org in un'unica passata (service_role).
-- Porting di process_pending_cancellations
-- (_legacy/.../20260309400000_process_pending_cancellations_cron.sql),
-- timezone per-org. NESSUNA logica credito.
create or replace function process_pending_cancellations()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_count        integer := 0;
    v_lesson_start timestamptz;
    v_tz           text;
    v_booking      record;
begin
    for v_booking in
        select b.id, b.date, b.time, o.timezone as tz
        from   bookings b
        join   organizations o on o.id = b.org_id
        where  b.status = 'cancellation_requested'
          -- solo le prossime 48h: non toccare storico
          and  b.date >= (now() - interval '24 hours')::date
          and  b.date <= (now() + interval '48 hours')::date
    loop
        v_tz := coalesce(v_booking.tz, 'Europe/Rome');
        -- orario di inizio dalla stringa "HH:MM - HH:MM" nel fuso della org
        v_lesson_start := (
            v_booking.date::text || ' ' ||
            trim(split_part(v_booking.time, ' - ', 1)) || ':00'
        )::timestamp at time zone v_tz;

        -- se mancano ≤ 2 ore → nega l'annullamento, riporta a confirmed
        if v_lesson_start - now() <= interval '2 hours' then
            update bookings set status = 'confirmed' where id = v_booking.id;
            v_count := v_count + 1;
        end if;
    end loop;

    return v_count;
end;
$$;
revoke all on function process_pending_cancellations() from public;
grant execute on function process_pending_cancellations() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO E — WORKOUT (org-scoped)
-- ─────────────────────────────────────────────────────────────────────────────

-- Duplica una scheda (plan + esercizi) su un altro cliente della stessa org.
-- Porting di admin_duplicate_plan (_legacy/.../20260412100000_duplicate_plan_with_slug.sql),
-- ora con org_id su plan ed esercizi + copia di circuit_group/superset_group/exercise_slug.
create or replace function admin_duplicate_plan(
    p_plan_id     uuid,
    p_new_user_id uuid,
    p_new_name    text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
    v_org         uuid := current_org_id();
    v_new_plan_id uuid;
    v_source      workout_plans%rowtype;
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;

    select * into v_source from workout_plans where id = p_plan_id and org_id = v_org;
    if not found then
        raise exception 'plan_not_found';
    end if;

    -- il cliente di destinazione deve appartenere alla stessa org
    if not exists (select 1 from profiles where id = p_new_user_id and org_id = v_org) then
        raise exception 'user_not_in_org';
    end if;

    insert into workout_plans (org_id, user_id, name, start_date, end_date, notes, active)
    values (
        v_org,
        p_new_user_id,
        coalesce(p_new_name, v_source.name),
        current_date,
        null,
        v_source.notes,
        true
    )
    returning id into v_new_plan_id;

    insert into workout_exercises (
        org_id, plan_id, day_label, exercise_name, exercise_slug, muscle_group,
        sort_order, sets, reps, weight_kg, rest_seconds, notes,
        superset_group, circuit_group
    )
    select
        v_org, v_new_plan_id, day_label, exercise_name, exercise_slug, muscle_group,
        sort_order, sets, reps, weight_kg, rest_seconds, notes,
        superset_group, circuit_group
    from workout_exercises
    where plan_id = p_plan_id and org_id = v_org
    order by sort_order;

    return v_new_plan_id;
end;
$$;
revoke all on function admin_duplicate_plan(uuid, uuid, text) from public;
grant execute on function admin_duplicate_plan(uuid, uuid, text) to authenticated;

-- Suggerimenti esercizi (autocomplete) per la propria org.
-- Porting di get_exercise_suggestions (_legacy/.../20260401000000_workout_plans.sql),
-- ora filtrato per current_org_id() su workout_exercises della org.
create or replace function get_exercise_suggestions()
returns table(exercise_name text)
language sql stable security definer set search_path = public as $$
    select distinct we.exercise_name
    from workout_exercises we
    where we.org_id = current_org_id()
    order by we.exercise_name;
$$;
revoke all on function get_exercise_suggestions() from public;
grant execute on function get_exercise_suggestions() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO F — MANUTENZIONE / RESET DATI (admin)
-- ─────────────────────────────────────────────────────────────────────────────

-- Azzeramento totale dei dati OPERATIVI della SOLA org corrente.
-- Cancella prenotazioni, incassi, pacchetti/abbonamenti, profili di
-- fatturazione cliente, workout (log → esercizi → schede), override di
-- calendario, notifiche e report mensili della org.
-- NON tocca: organizations, org_members, profiles, plans, subscriptions
-- (anagrafica/account e billing-SaaS restano intatti).
-- Solo org admin della org corrente. Nessun riferimento a tabelle credito
-- (credits/credit_history/manual_debts/bonuses) perché non esistono più.
create or replace function admin_clear_all_data()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org uuid := current_org_id();
begin
    if not is_org_admin(v_org) then
        raise exception 'unauthorized';
    end if;

    -- Ordine FK-safe: prima i figli, poi i padri.
    -- payments referenzia bookings/memberships/packages (on delete set null),
    -- ma lo eliminiamo per primo per non lasciare righe orfane post-reset.
    delete from payments                where org_id = v_org;

    -- workout: log → esercizi → schede
    delete from workout_logs            where org_id = v_org;
    delete from workout_exercises       where org_id = v_org;
    delete from workout_plans           where org_id = v_org;

    -- billing-cliente (stato cliente)
    delete from client_packages         where org_id = v_org;
    delete from client_memberships      where org_id = v_org;
    delete from client_billing_profiles where org_id = v_org;

    -- calendario puntuale + prenotazioni
    delete from schedule_overrides      where org_id = v_org;
    delete from bookings                where org_id = v_org;

    -- notifiche / messaggi / report
    delete from client_notifications    where org_id = v_org;
    delete from admin_messages          where org_id = v_org;
    delete from monthly_reports         where org_id = v_org;

    return jsonb_build_object('success', true, 'org_id', v_org);
end;
$$;
revoke all on function admin_clear_all_data() from public, anon;
grant execute on function admin_clear_all_data() to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- BLOCCO G — Gestione cliente (rinomina / elimina dati) org-scoped, no credito
-- ─────────────────────────────────────────────────────────────────────────────

-- Rinomina/aggiorna un cliente: allinea profilo + prenotazioni della propria org.
-- (La versione legacy toccava anche credits/manual_debts: tabelle ora rimosse.)
create or replace function admin_rename_client(
    p_old_email    text,
    p_old_whatsapp text default null,
    p_new_name     text default null,
    p_new_email    text default null,
    p_new_whatsapp text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_org      uuid := current_org_id();
    v_old_mail text := lower(trim(coalesce(p_old_email, '')));
    v_new_mail text := lower(trim(coalesce(p_new_email, '')));
    v_prof     integer := 0;
    v_book     integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;

    update profiles set
        name     = coalesce(nullif(trim(coalesce(p_new_name,'')),''), name),
        email    = coalesce(nullif(v_new_mail,''), email),
        whatsapp = coalesce(p_new_whatsapp, whatsapp)
    where org_id = v_org
      and ( (v_old_mail <> '' and lower(email) = v_old_mail)
            or (p_old_whatsapp is not null and whatsapp = p_old_whatsapp) );
    get diagnostics v_prof = row_count;

    update bookings set
        name     = coalesce(nullif(trim(coalesce(p_new_name,'')),''), name),
        email    = coalesce(nullif(v_new_mail,''), email),
        whatsapp = coalesce(p_new_whatsapp, whatsapp)
    where org_id = v_org
      and ( (v_old_mail <> '' and lower(email) = v_old_mail)
            or (p_old_whatsapp is not null and whatsapp = p_old_whatsapp) );
    get diagnostics v_book = row_count;

    return jsonb_build_object('success', true, 'profiles_updated', v_prof, 'bookings_updated', v_book);
end;
$$;
revoke all on function admin_rename_client(text,text,text,text,text) from public, anon;
grant execute on function admin_rename_client(text,text,text,text,text) to authenticated;

-- Elimina i dati operativi di un cliente (prenotazioni) della propria org.
-- payments.booking_id ha ON DELETE SET NULL → lo storico incassi resta nel ledger.
create or replace function admin_delete_client_data(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
    v_org  uuid := current_org_id();
    v_mail text := lower(trim(coalesce(p_email, '')));
    v_del  integer := 0;
begin
    if not is_org_admin(v_org) then raise exception 'unauthorized'; end if;
    if v_mail = '' then return jsonb_build_object('success', false, 'error', 'missing_email'); end if;

    delete from bookings where org_id = v_org and lower(email) = v_mail;
    get diagnostics v_del = row_count;

    return jsonb_build_object('success', true, 'bookings_deleted', v_del);
end;
$$;
revoke all on function admin_delete_client_data(text) from public, anon;
grant execute on function admin_delete_client_data(text) to authenticated;
