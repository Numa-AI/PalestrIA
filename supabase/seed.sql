-- ══════════════════════════════════════════════════════════════════════════════
-- PalestrIA SaaS — Seed demo per `supabase db reset`
--
-- Crea UNA organization demo (slug 'demo-studio') con un setup di scheduling
-- realistico, così l'app ha dati da mostrare subito dopo un reset locale.
--
-- NOTE:
--  - NON inseriamo utenti auth: owner/staff/clienti arrivano dal signup reale
--    (l'auth hook inietta poi i claim org_id/org_role). owner_user_id resta NULL.
--  - I piani SaaS ('plans') sono GIA' nel baseline: qui NON li reinseriamo.
--  - Idempotente: usa ON CONFLICT / guardie così un doppio run non duplica nulla.
--  - I nomi di colonna seguono esattamente la baseline.
-- ══════════════════════════════════════════════════════════════════════════════

do $$
declare
    v_org      uuid;
    v_tpl      uuid;
    -- slot types
    v_pt       uuid;   -- personal-training
    v_sg       uuid;   -- small-group
    v_gc       uuid;   -- group-class
    -- fasce orarie (time_slots_config)
    v_ts_0900  uuid;
    v_ts_1000  uuid;
    v_ts_1100  uuid;
    v_ts_1700  uuid;
    v_ts_1800  uuid;
    v_ts_1900  uuid;
    v_ts_2000  uuid;
    v_wd       smallint;
begin
    -- ── ORGANIZATION demo ────────────────────────────────────────────────────
    -- owner_user_id NULL: lo studio demo non ha (ancora) un owner autenticato.
    insert into organizations (name, slug, owner_user_id, timezone, currency, locale, status, created_via)
    values ('Demo Studio', 'demo-studio', null, 'Europe/Rome', 'EUR', 'it', 'trialing', 'seed')
    on conflict (slug) do nothing;

    select id into v_org from organizations where slug = 'demo-studio';
    if v_org is null then
        raise notice 'seed: organization demo-studio non creata, esco.';
        return;
    end if;

    -- ── BILLING-CLIENTE: impostazioni di default della org ────────────────────
    insert into billing_settings (org_id, default_model)
    values (v_org, 'pay_per_session')
    on conflict (org_id) do nothing;

    -- ── SLOT TYPES ────────────────────────────────────────────────────────────
    insert into slot_types (org_id, key, label, color, default_capacity, default_price, bookable, is_active, sort_order)
    values
        (v_org, 'personal-training', 'Personal Training', '#8B5CF6', 1,  35.00, true, true, 0),
        (v_org, 'small-group',       'Small Group',        '#22C55E', 5,  15.00, true, true, 1),
        (v_org, 'group-class',       'Group Class',        '#F59E0B', 12, 10.00, true, true, 2)
    on conflict (org_id, key) do nothing;

    select id into v_pt from slot_types where org_id = v_org and key = 'personal-training';
    select id into v_sg from slot_types where org_id = v_org and key = 'small-group';
    select id into v_gc from slot_types where org_id = v_org and key = 'group-class';

    -- ── TIME SLOTS CONFIG (mattina + pomeriggio/sera) ─────────────────────────
    insert into time_slots_config (org_id, start_time, end_time, label, sort_order, is_active)
    values
        (v_org, '09:00', '10:00', 'Mattina',   0, true),
        (v_org, '10:00', '11:00', 'Mattina',   1, true),
        (v_org, '11:00', '12:00', 'Mattina',   2, true),
        (v_org, '17:00', '18:00', 'Pomeriggio',3, true),
        (v_org, '18:00', '19:00', 'Sera',      4, true),
        (v_org, '19:00', '20:00', 'Sera',      5, true),
        (v_org, '20:00', '21:00', 'Sera',      6, true)
    on conflict (org_id, start_time, end_time) do nothing;

    select id into v_ts_0900 from time_slots_config where org_id = v_org and start_time = '09:00' and end_time = '10:00';
    select id into v_ts_1000 from time_slots_config where org_id = v_org and start_time = '10:00' and end_time = '11:00';
    select id into v_ts_1100 from time_slots_config where org_id = v_org and start_time = '11:00' and end_time = '12:00';
    select id into v_ts_1700 from time_slots_config where org_id = v_org and start_time = '17:00' and end_time = '18:00';
    select id into v_ts_1800 from time_slots_config where org_id = v_org and start_time = '18:00' and end_time = '19:00';
    select id into v_ts_1900 from time_slots_config where org_id = v_org and start_time = '19:00' and end_time = '20:00';
    select id into v_ts_2000 from time_slots_config where org_id = v_org and start_time = '20:00' and end_time = '21:00';

    -- ── WEEKLY SCHEDULE TEMPLATE attivo ───────────────────────────────────────
    insert into weekly_schedule_templates (org_id, name, is_active)
    values (v_org, 'Settimana tipo', true)
    on conflict do nothing;

    select id into v_tpl from weekly_schedule_templates
        where org_id = v_org and name = 'Settimana tipo'
        order by created_at desc limit 1;

    -- ── WEEKLY TEMPLATE SLOTS ─────────────────────────────────────────────────
    -- weekday: 0=Domenica ... 6=Sabato. Programmiamo Lun(1)/Mer(3)/Ven(5).
    -- Mattina: Personal Training. Sera: Small Group / Group Class.
    if v_tpl is not null then
        foreach v_wd in array array[1, 3, 5]::smallint[] loop
            insert into weekly_template_slots (template_id, org_id, weekday, time_slot_id, slot_type_id, capacity)
            values
                -- mattina: personal training 1-a-1
                (v_tpl, v_org, v_wd, v_ts_0900, v_pt, 1),
                (v_tpl, v_org, v_wd, v_ts_1000, v_pt, 1),
                (v_tpl, v_org, v_wd, v_ts_1100, v_pt, 1),
                -- pomeriggio/sera: gruppi
                (v_tpl, v_org, v_wd, v_ts_1700, v_sg, 5),
                (v_tpl, v_org, v_wd, v_ts_1800, v_gc, 12),
                (v_tpl, v_org, v_wd, v_ts_1900, v_gc, 12),
                (v_tpl, v_org, v_wd, v_ts_2000, v_sg, 5)
            on conflict (template_id, weekday, time_slot_id) do nothing;
        end loop;
    end if;

    -- ── ATTIVAZIONE SETTIMANE (per-settimana, manuale) ────────────────────────
    -- Attiviamo la settimana corrente e le 3 successive sul template demo, così
    -- il calendario non è vuoto appena seedato. Le altre settimane restano da
    -- attivare a mano dall'editor orari.
    if v_tpl is not null then
        for v_wd in 0..3 loop
            insert into activated_weeks (org_id, week_start, template_id)
            values (v_org, (date_trunc('week', now())::date + (v_wd * 7)), v_tpl)
            on conflict (org_id, week_start) do nothing;
        end loop;
    end if;

    -- ── ORG SETTINGS di base per la demo ──────────────────────────────────────
    insert into org_settings (org_id, key, value) values
        (v_org, 'branding.studio_name',     to_jsonb('Demo Studio'::text)),
        (v_org, 'branding.primary_color',   to_jsonb('#8B5CF6'::text)),
        (v_org, 'locale.timezone',          to_jsonb('Europe/Rome'::text)),
        (v_org, 'locale.currency',          to_jsonb('EUR'::text)),
        (v_org, 'booking.policy.free_cancel_hours',to_jsonb(24)),
        (v_org, 'booking.policy.penalty_pct',      to_jsonb(50))
    on conflict (org_id, key) do nothing;

    raise notice 'seed: org demo-studio pronta (id=%).', v_org;
end $$;
