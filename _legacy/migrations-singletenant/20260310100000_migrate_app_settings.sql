-- ─── MIGRAZIONE DATI: app_settings → tabelle dedicate ────────────────────────
-- Eseguire UNA SOLA VOLTA nel SQL Editor di Supabase.
-- Legge i blob JSON da app_settings e popola le tabelle strutturate.
-- I dati in app_settings non vengono eliminati (cleanup separato al go-live).
-- Idempotente: usa ON CONFLICT DO UPDATE / DO NOTHING.

-- ── 1. Credits ────────────────────────────────────────────────────────────────
do $$
declare
    v_blob      jsonb;
    v_key       text;
    v_rec       jsonb;
    v_credit_id uuid;
    v_entry     jsonb;
    v_note      text;
begin
    select value into v_blob from app_settings where key = 'gym_credits';
    if v_blob is null or v_blob = '{}'::jsonb then
        raise notice 'gym_credits: vuoto, skip';
        return;
    end if;

    for v_key, v_rec in select * from jsonb_each(v_blob) loop
        insert into credits (name, whatsapp, email, balance, user_id)
        values (
            v_rec->>'name',
            v_rec->>'whatsapp',
            lower(v_rec->>'email'),
            coalesce((v_rec->>'balance')::numeric, 0),
            (select id from profiles where lower(email) = lower(v_rec->>'email') limit 1)
        )
        on conflict (email) do update set
            name     = excluded.name,
            whatsapp = excluded.whatsapp,
            balance  = excluded.balance,
            user_id  = coalesce(excluded.user_id, credits.user_id)
        returning id into v_credit_id;

        -- Svuota la history esistente per evitare duplicati se la migration viene rieseguita
        delete from credit_history where credit_id = v_credit_id;

        -- Inserisce le voci di history
        for v_entry in select * from jsonb_array_elements(coalesce(v_rec->'history', '[]'::jsonb)) loop
            -- Compatta method e displayAmount nel note se presenti
            v_note := v_entry->>'note';
            if (v_entry->>'method') is not null then
                v_note := v_note || ' [' || (v_entry->>'method') || ']';
            end if;
            if (v_entry->>'displayAmount') is not null then
                v_note := v_note || ' €' || (v_entry->>'displayAmount');
            end if;

            insert into credit_history (credit_id, amount, note, created_at)
            values (
                v_credit_id,
                (v_entry->>'amount')::numeric,
                v_note,
                coalesce((v_entry->>'date')::timestamptz, now())
            );
        end loop;
    end loop;

    raise notice 'Credits migrati con successo';
end $$;

-- ── 2. Manual Debts ───────────────────────────────────────────────────────────
do $$
declare
    v_blob jsonb;
    v_key  text;
    v_rec  jsonb;
begin
    select value into v_blob from app_settings where key = 'gym_manual_debts';
    if v_blob is null or v_blob = '{}'::jsonb then
        raise notice 'gym_manual_debts: vuoto, skip';
        return;
    end if;

    for v_key, v_rec in select * from jsonb_each(v_blob) loop
        -- Usa email come chiave di dedup (non c'è unique constraint → controlla a mano)
        if not exists (select 1 from manual_debts where lower(email) = lower(v_rec->>'email')) then
            insert into manual_debts (name, whatsapp, email, balance, history, user_id)
            values (
                v_rec->>'name',
                v_rec->>'whatsapp',
                lower(v_rec->>'email'),
                coalesce((v_rec->>'balance')::numeric, 0),
                coalesce(v_rec->'history', '[]'::jsonb),
                (select id from profiles where lower(email) = lower(v_rec->>'email') limit 1)
            );
        else
            update manual_debts set
                balance  = coalesce((v_rec->>'balance')::numeric, 0),
                history  = coalesce(v_rec->'history', '[]'::jsonb),
                user_id  = coalesce(
                    (select id from profiles where lower(email) = lower(v_rec->>'email') limit 1),
                    user_id
                )
            where lower(email) = lower(v_rec->>'email');
        end if;
    end loop;

    raise notice 'Manual debts migrati con successo';
end $$;

-- ── 3. Bonuses ────────────────────────────────────────────────────────────────
do $$
declare
    v_blob jsonb;
    v_key  text;
    v_rec  jsonb;
begin
    select value into v_blob from app_settings where key = 'gym_bonus';
    if v_blob is null or v_blob = '{}'::jsonb then
        raise notice 'gym_bonus: vuoto, skip';
        return;
    end if;

    for v_key, v_rec in select * from jsonb_each(v_blob) loop
        insert into bonuses (name, whatsapp, email, bonus, last_reset_month, user_id)
        values (
            v_rec->>'name',
            v_rec->>'whatsapp',
            lower(v_rec->>'email'),
            coalesce((v_rec->>'bonus')::integer, 1),
            v_rec->>'lastResetMonth',
            (select id from profiles where lower(email) = lower(v_rec->>'email') limit 1)
        )
        on conflict (email) do update set
            bonus            = excluded.bonus,
            last_reset_month = excluded.last_reset_month,
            user_id          = coalesce(excluded.user_id, bonuses.user_id);
    end loop;

    raise notice 'Bonuses migrati con successo';
end $$;

-- ── 4. Schedule Overrides ─────────────────────────────────────────────────────
-- Formato: { "YYYY-MM-DD": [ {time, type, extras?}, ... ] }
-- Gli "extras" (slot aggiuntivi sullo stesso orario) non hanno colonna dedicata → ignorati.
do $$
declare
    v_blob     jsonb;
    v_date_str text;
    v_slots    jsonb;
    v_slot     jsonb;
begin
    select value into v_blob from app_settings where key = 'scheduleOverrides';
    if v_blob is null or v_blob = '{}'::jsonb then
        raise notice 'scheduleOverrides: vuoto, skip';
        return;
    end if;

    for v_date_str, v_slots in select * from jsonb_each(v_blob) loop
        for v_slot in select * from jsonb_array_elements(v_slots) loop
            insert into schedule_overrides (date, time, slot_type)
            values (
                v_date_str::date,
                v_slot->>'time',
                v_slot->>'type'
            )
            on conflict (date, time) do update set
                slot_type = excluded.slot_type;
        end loop;
    end loop;

    raise notice 'Schedule overrides migrati con successo';
end $$;

-- ── 5. Settings primitive ─────────────────────────────────────────────────────
-- Mappa: gym_debt_threshold → debt_threshold
--        gym_cancellation_mode → cancellation_mode
--        gym_cert_scadenza_editable → cert_scadenza_editable
do $$
declare
    v_val  jsonb;
    v_text text;
begin
    -- debt_threshold
    select value into v_val from app_settings where key = 'gym_debt_threshold';
    if v_val is not null then
        v_text := case jsonb_typeof(v_val)
            when 'string' then v_val #>> '{}'
            else v_val::text
        end;
        insert into settings (key, value) values ('debt_threshold', v_text)
        on conflict (key) do update set value = excluded.value, updated_at = now();
    end if;

    -- cancellation_mode
    select value into v_val from app_settings where key = 'gym_cancellation_mode';
    if v_val is not null then
        v_text := case jsonb_typeof(v_val)
            when 'string' then v_val #>> '{}'
            else v_val::text
        end;
        insert into settings (key, value) values ('cancellation_mode', v_text)
        on conflict (key) do update set value = excluded.value, updated_at = now();
    end if;

    -- cert_scadenza_editable
    select value into v_val from app_settings where key = 'gym_cert_scadenza_editable';
    if v_val is not null then
        v_text := case jsonb_typeof(v_val)
            when 'string' then v_val #>> '{}'
            else v_val::text
        end;
        insert into settings (key, value) values ('cert_scadenza_editable', v_text)
        on conflict (key) do update set value = excluded.value, updated_at = now();
    end if;

    raise notice 'Settings migrati con successo';
end $$;
