-- ─────────────────────────────────────────────────────────────────────────────
-- 00000000000016 — KIOSK RPCs (tablet.html)  [fix C2]
-- ─────────────────────────────────────────────────────────────────────────────
-- Il tablet (tablet.html) è un kiosk condiviso SENZA modello di auth proprio:
-- storicamente riusava la sessione admin lasciata in localStorage → operava con
-- privilegi admin sull'INTERA org (data-leak/abuso, vedi audit C2).
--
-- Nuovo modello: il kiosk gira ANONIMO (client Supabase con storageKey isolato,
-- nessun token utente) e passa SEMPRE per queste RPC SECURITY DEFINER, ognuna
-- vincolata al solo `p_uid` scansionato dal QR. Stesso modello di fiducia di
-- get_slot_attendees (anon, scoping esplicito): per leggere/scrivere i dati di
-- allenamento di un cliente serve conoscerne l'uid (UUID v4 nel QR), e l'accesso
-- è limitato ESCLUSIVAMENTE ai dati di allenamento di QUEL cliente — niente più
-- privilegi admin sull'org. Ogni scrittura valida l'ownership riga-per-riga.
-- ─────────────────────────────────────────────────────────────────────────────

-- Helper interno: true se l'esercizio appartiene a un piano del cliente p_uid.
create or replace function _kiosk_owns_exercise(p_uid uuid, p_ex_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (
        select 1
        from   workout_exercises we
        join   workout_plans wp on wp.id = we.plan_id
        where  we.id = p_ex_id and wp.user_id = p_uid
    );
$$;
revoke all on function _kiosk_owns_exercise(uuid, uuid) from public;

-- ── LETTURA scheda attiva + esercizi + log (ultimi 30 gg) ────────────────────
create or replace function kiosk_load_workout(p_uid uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
    v_plan workout_plans;
begin
    if p_uid is null then return null; end if;

    select * into v_plan
    from   workout_plans
    where  user_id = p_uid and active = true
    order by updated_at desc
    limit  1;

    if v_plan.id is null then
        return jsonb_build_object(
            'user_name', coalesce((select name from profiles where id = p_uid), 'Utente'),
            'plan', null, 'exercises', '[]'::jsonb, 'logs', '[]'::jsonb);
    end if;

    return jsonb_build_object(
        'user_name', coalesce((select name from profiles where id = p_uid), 'Utente'),
        'plan', to_jsonb(v_plan),
        'exercises', coalesce((
            select jsonb_agg(to_jsonb(we) order by we.sort_order)
            from   workout_exercises we where we.plan_id = v_plan.id), '[]'::jsonb),
        'logs', coalesce((
            select jsonb_agg(to_jsonb(wl))
            from   workout_logs wl
            join   workout_exercises we2 on we2.id = wl.exercise_id
            where  we2.plan_id = v_plan.id
              and  wl.user_id = p_uid
              and  wl.log_date >= current_date - 30), '[]'::jsonb)
    );
end;
$$;
revoke all on function kiosk_load_workout(uuid) from public;
grant execute on function kiosk_load_workout(uuid) to anon, authenticated;

-- ── LETTURA progressi: tutti gli esercizi del cliente + log (ultimi 90 gg) ───
create or replace function kiosk_load_progress(p_uid uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
    if p_uid is null then return null; end if;
    return jsonb_build_object(
        'exercises', coalesce((
            select jsonb_agg(jsonb_build_object(
                'id', we.id, 'exercise_name', we.exercise_name,
                'muscle_group', we.muscle_group, 'sets', we.sets,
                'reps', we.reps, 'weight_kg', we.weight_kg))
            from   workout_exercises we
            join   workout_plans wp on wp.id = we.plan_id
            where  wp.user_id = p_uid), '[]'::jsonb),
        'logs', coalesce((
            select jsonb_agg(jsonb_build_object(
                'exercise_id', wl.exercise_id, 'log_date', wl.log_date,
                'set_number', wl.set_number, 'reps_done', wl.reps_done,
                'weight_done', wl.weight_done) order by wl.log_date)
            from   workout_logs wl
            join   workout_exercises we on we.id = wl.exercise_id
            join   workout_plans wp on wp.id = we.plan_id
            where  wp.user_id = p_uid
              and  wl.user_id = p_uid
              and  wl.log_date >= current_date - 90), '[]'::jsonb)
    );
end;
$$;
revoke all on function kiosk_load_progress(uuid) from public;
grant execute on function kiosk_load_progress(uuid) to anon, authenticated;

-- ── Catalogo esercizi visibile alla org del cliente (globale + per-org) ──────
create or replace function kiosk_exercise_catalog(p_uid uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
    v_org uuid;
begin
    if p_uid is null then return '[]'::jsonb; end if;
    select org_id into v_org from profiles where id = p_uid;
    return coalesce((
        select jsonb_agg(jsonb_build_object(
            'nome_it', nome_it, 'nome_en', nome_en, 'categoria', categoria,
            'slug', slug, 'immagine', immagine,
            'immagine_thumbnail', immagine_thumbnail, 'video', video))
        from   imported_exercises
        where  org_id is null or org_id = v_org), '[]'::jsonb);
end;
$$;
revoke all on function kiosk_exercise_catalog(uuid) from public;
grant execute on function kiosk_exercise_catalog(uuid) to anon, authenticated;

-- ── SCRITTURA log (upsert batch) ─────────────────────────────────────────────
-- p_logs: [{exercise_id, log_date, set_number, reps_done, weight_done}, ...]
create or replace function kiosk_save_logs(p_uid uuid, p_logs jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_row   jsonb;
    v_ex    uuid;
    v_org   uuid;
    v_out   jsonb := '[]'::jsonb;
    v_saved workout_logs;
begin
    if p_uid is null or p_logs is null then return v_out; end if;

    for v_row in select * from jsonb_array_elements(p_logs) loop
        v_ex := (v_row->>'exercise_id')::uuid;
        -- Ownership: l'esercizio deve appartenere a un piano del cliente.
        select org_id into v_org from workout_exercises where id = v_ex;
        if v_org is null or not _kiosk_owns_exercise(p_uid, v_ex) then
            continue;  -- riga non di proprietà: scartata in silenzio
        end if;

        insert into workout_logs (org_id, exercise_id, user_id, log_date, set_number, reps_done, weight_done)
        values (v_org, v_ex, p_uid,
                (v_row->>'log_date')::date,
                (v_row->>'set_number')::int,
                nullif(v_row->>'reps_done','')::int,
                nullif(v_row->>'weight_done','')::numeric)
        on conflict (exercise_id, user_id, log_date, set_number)
        do update set reps_done = excluded.reps_done, weight_done = excluded.weight_done
        returning * into v_saved;

        v_out := v_out || to_jsonb(v_saved);
    end loop;

    return v_out;
end;
$$;
revoke all on function kiosk_save_logs(uuid, jsonb) from public;
grant execute on function kiosk_save_logs(uuid, jsonb) to anon, authenticated;

-- ── ELIMINA log del giorno per un esercizio ──────────────────────────────────
create or replace function kiosk_delete_logs(p_uid uuid, p_exercise_id uuid, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not _kiosk_owns_exercise(p_uid, p_exercise_id) then return; end if;
    delete from workout_logs
    where  exercise_id = p_exercise_id and user_id = p_uid and log_date = p_date;
end;
$$;
revoke all on function kiosk_delete_logs(uuid, uuid, date) from public;
grant execute on function kiosk_delete_logs(uuid, uuid, date) to anon, authenticated;

-- ── MODIFICA esercizio (campi consentiti) ────────────────────────────────────
create or replace function kiosk_update_exercise(p_uid uuid, p_ex_id uuid, p_updates jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_row workout_exercises;
begin
    if not _kiosk_owns_exercise(p_uid, p_ex_id) then return null; end if;
    update workout_exercises set
        sets         = coalesce((p_updates->>'sets')::int,        sets),
        reps         = coalesce(p_updates->>'reps',               reps),
        weight_kg    = case when p_updates ? 'weight_kg'    then nullif(p_updates->>'weight_kg','')::numeric  else weight_kg    end,
        rest_seconds = case when p_updates ? 'rest_seconds' then nullif(p_updates->>'rest_seconds','')::int   else rest_seconds end,
        notes        = case when p_updates ? 'notes'        then nullif(p_updates->>'notes','')               else notes        end
    where id = p_ex_id
    returning * into v_row;
    return to_jsonb(v_row);
end;
$$;
revoke all on function kiosk_update_exercise(uuid, uuid, jsonb) from public;
grant execute on function kiosk_update_exercise(uuid, uuid, jsonb) to anon, authenticated;

-- ── AGGIUNGI esercizi (singolo o coppia super-serie) al piano ────────────────
-- p_rows: [{day_label, exercise_name, muscle_group, sort_order, sets, reps,
--           weight_kg, rest_seconds, notes, superset_group}, ...]
create or replace function kiosk_add_exercises(p_uid uuid, p_plan_id uuid, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
    v_org uuid;
    v_row jsonb;
    v_out jsonb := '[]'::jsonb;
    v_new workout_exercises;
begin
    -- Ownership: il piano deve appartenere al cliente.
    select org_id into v_org from workout_plans where id = p_plan_id and user_id = p_uid;
    if v_org is null then return v_out; end if;

    for v_row in select * from jsonb_array_elements(p_rows) loop
        insert into workout_exercises
            (org_id, plan_id, day_label, exercise_name, muscle_group, sort_order,
             sets, reps, weight_kg, rest_seconds, notes, superset_group)
        values
            (v_org, p_plan_id,
             coalesce(v_row->>'day_label','Giorno A'),
             v_row->>'exercise_name',
             v_row->>'muscle_group',
             coalesce((v_row->>'sort_order')::int, 0),
             coalesce((v_row->>'sets')::int, 3),
             coalesce(v_row->>'reps','10'),
             nullif(v_row->>'weight_kg','')::numeric,
             nullif(v_row->>'rest_seconds','')::int,
             nullif(v_row->>'notes',''),
             nullif(v_row->>'superset_group','')::uuid)
        returning * into v_new;
        v_out := v_out || to_jsonb(v_new);
    end loop;

    return v_out;
end;
$$;
revoke all on function kiosk_add_exercises(uuid, uuid, jsonb) from public;
grant execute on function kiosk_add_exercises(uuid, uuid, jsonb) to anon, authenticated;

-- ── RIORDINA esercizi ────────────────────────────────────────────────────────
-- p_orders: [{id, sort_order}, ...]
create or replace function kiosk_reorder_exercises(p_uid uuid, p_orders jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_row jsonb;
    v_id  uuid;
begin
    for v_row in select * from jsonb_array_elements(p_orders) loop
        v_id := (v_row->>'id')::uuid;
        if _kiosk_owns_exercise(p_uid, v_id) then
            update workout_exercises set sort_order = (v_row->>'sort_order')::int where id = v_id;
        end if;
    end loop;
end;
$$;
revoke all on function kiosk_reorder_exercises(uuid, jsonb) from public;
grant execute on function kiosk_reorder_exercises(uuid, jsonb) to anon, authenticated;

-- ── ELIMINA esercizio singolo ────────────────────────────────────────────────
create or replace function kiosk_delete_exercise(p_uid uuid, p_ex_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if not _kiosk_owns_exercise(p_uid, p_ex_id) then return; end if;
    delete from workout_exercises where id = p_ex_id;
end;
$$;
revoke all on function kiosk_delete_exercise(uuid, uuid) from public;
grant execute on function kiosk_delete_exercise(uuid, uuid) to anon, authenticated;

-- ── ELIMINA super-serie (tutti gli esercizi del gruppo, solo se del cliente) ──
create or replace function kiosk_delete_superset(p_uid uuid, p_group_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
    delete from workout_exercises we
    using  workout_plans wp
    where  we.plan_id = wp.id
      and  wp.user_id = p_uid
      and  we.superset_group = p_group_id;
end;
$$;
revoke all on function kiosk_delete_superset(uuid, uuid) from public;
grant execute on function kiosk_delete_superset(uuid, uuid) to anon, authenticated;

-- ── RINOMINA scheda ──────────────────────────────────────────────────────────
create or replace function kiosk_rename_plan(p_uid uuid, p_plan_id uuid, p_name text)
returns void
language plpgsql security definer set search_path = public as $$
begin
    update workout_plans set name = p_name
    where  id = p_plan_id and user_id = p_uid;
end;
$$;
revoke all on function kiosk_rename_plan(uuid, uuid, text) from public;
grant execute on function kiosk_rename_plan(uuid, uuid, text) to anon, authenticated;
