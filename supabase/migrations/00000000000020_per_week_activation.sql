-- ════════════════════════════════════════════════════════════════════════════
-- Attivazione del calendario PER-SETTIMANA (manuale, una settimana alla volta)
--
-- Modello precedente: un solo weekly_schedule_template con is_active=true veniva
-- replicato IDENTICO su tutte le settimane future all'infinito. Attivare un
-- template = attivare "tutto il calendario allo stesso modo".
--
-- Modello nuovo: ogni settimana CONCRETA del calendario va attivata manualmente e
-- punta a un template scelto (anche diverso per settimane diverse). Le settimane
-- non attivate non hanno slot (niente disponibilità, niente prenotazioni). Le
-- settimane già attivate restano invariate quando se ne attiva una nuova.
--
-- weekly_schedule_templates.is_active resta nello schema ma NON guida più la
-- risoluzione: è usato solo lato editor come "template di default" selezionato.
-- ════════════════════════════════════════════════════════════════════════════

create table if not exists activated_weeks (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references organizations(id) on delete cascade,
    week_start  date not null,   -- lunedì della settimana (date_trunc('week', d))
    template_id uuid not null references weekly_schedule_templates(id) on delete cascade,
    created_at  timestamptz not null default now(),
    unique (org_id, week_start)
);
create index if not exists activated_weeks_lookup_idx on activated_weeks (org_id, week_start);

alter table activated_weeks enable row level security;

-- Policy uniformi org-scoped (come weekly_schedule_templates): lettura per la
-- propria org, scrittura solo owner/admin. Gli anonimi NON leggono direttamente:
-- la disponibilità pubblica passa da resolve_slot_config (SECURITY DEFINER).
drop policy if exists activated_weeks_read on activated_weeks;
create policy activated_weeks_read on activated_weeks
    for select to authenticated using (org_id = current_org_id());

drop policy if exists activated_weeks_admin on activated_weeks;
create policy activated_weeks_admin on activated_weeks
    for all to authenticated
    using (is_org_admin(org_id)) with check (is_org_admin(org_id));

-- ── resolve_slot_config: il template ora viene dalla SETTIMANA ATTIVATA che
--    contiene p_date (non più dal singolo template is_active). Se la settimana
--    non è attivata → nessuno slot prenotabile (step 3).
create or replace function resolve_slot_config(p_org_id uuid, p_date date, p_time text)
returns table(slot_type text, slot_type_id uuid, capacity integer, price numeric, bookable boolean)
language plpgsql stable security definer set search_path = public as $$
declare
    v_ovr        schedule_overrides%rowtype;
    v_ts_id      uuid;
    v_tpl_id     uuid;
    v_weekday    smallint := extract(dow from p_date)::smallint;  -- 0=Domenica
    v_st_id      uuid;
    v_cap        integer;
begin
    -- 1) override per data (precedenza assoluta, indipendente dall'attivazione)
    select * into v_ovr from schedule_overrides
        where org_id = p_org_id and date = p_date and time = p_time;
    if found then
        select st.key, st.id, coalesce(v_ovr.capacity, st.default_capacity), st.default_price, st.bookable
            into slot_type, slot_type_id, capacity, price, bookable
            from slot_types st where st.id = v_ovr.slot_type_id;
        if not found then
            slot_type := v_ovr.slot_type; slot_type_id := null;
            capacity  := coalesce(v_ovr.capacity, 0); price := 0; bookable := true;
        end if;
        return next; return;
    end if;

    -- 2) template della SETTIMANA ATTIVATA che contiene p_date
    --    date_trunc('week') restituisce il lunedì → confronto con week_start.
    select aw.template_id into v_tpl_id from activated_weeks aw
        where aw.org_id = p_org_id
          and aw.week_start = (date_trunc('week', p_date::timestamp)::date);
    select id into v_ts_id from time_slots_config
        where org_id = p_org_id
          and (to_char(start_time, 'HH24:MI') || ' - ' || to_char(end_time, 'HH24:MI')) = p_time
        limit 1;
    if v_tpl_id is not null and v_ts_id is not null then
        select wts.slot_type_id, coalesce(wts.capacity, st.default_capacity)
            into v_st_id, v_cap
            from weekly_template_slots wts
            join slot_types st on st.id = wts.slot_type_id
            where wts.template_id = v_tpl_id and wts.weekday = v_weekday and wts.time_slot_id = v_ts_id;
        if found then
            select st.key, st.id, v_cap, st.default_price, st.bookable
                into slot_type, slot_type_id, capacity, price, bookable
                from slot_types st where st.id = v_st_id;
            return next; return;
        end if;
    end if;

    -- 3) settimana non attivata o slot non configurato → non prenotabile
    slot_type := null; slot_type_id := null; capacity := 0; price := 0; bookable := false;
    return next;
end;
$$;
