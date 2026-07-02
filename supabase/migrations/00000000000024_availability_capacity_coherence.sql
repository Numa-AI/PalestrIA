-- ──────────────────────────────────────────────────────────────────────────────
-- 00000000000024_availability_capacity_coherence
--
-- Port (code review 2, finding #1 HIGH) dal gemello Thomas, adattato al SaaS.
--
-- BUG: incoerenza nel conteggio della capienza tra il percorso AUTORITATIVO e le
-- letture di disponibilità.
--   • `book_slot` (autorità server, baseline + 00000000000010) conta i posti con
--     status IN ('confirmed','cancellation_requested') — coerente con l'indice
--     parziale `bookings_active_slot_idx` della baseline.
--   • `get_availability_range` / `get_slot_availability` (00000000000001) e il client
--     `getRemainingSpots` (js/data.js) contavano SOLO 'confirmed'.
-- Effetto: uno slot pieno con una richiesta di annullamento pendente
-- (`cancellation_requested`) mostra "1 posto libero" nella UI, ma `book_slot`
-- risponde `slot_full` → posto fantasma non prenotabile da nessun percorso e flusso
-- "richiedi annullamento" mai soddisfatto da un pari.
--
-- FIX: allineare le due RPC di disponibilità a contare gli stessi status di
-- `book_slot` (confirmed + cancellation_requested = "posti occupati"). Il client
-- `getRemainingSpots` è allineato a parte in js/data.js.
--
-- Nota: il campo JSON resta `confirmed_count` per retro-compatibilità dei chiamanti,
-- ma ora rappresenta i posti OCCUPATI (confirmed + cancellation_requested).
-- `get_slot_attendees` NON viene toccata: la lista iscritti resta 'confirmed' (scelta
-- di UX separata dal conteggio capienza).
--
-- Incrementale sopra la baseline già applicata. Idempotente (CREATE OR REPLACE).
-- ──────────────────────────────────────────────────────────────────────────────

-- Disponibilità su un range di date (aggregati, pubblica/anonima via slug).
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
              and b.status in ('confirmed', 'cancellation_requested')  -- allineato a book_slot
            group by b.date, b.time, b.slot_type
        ) agg
        cross join lateral resolve_slot_config(v_org, agg.date, agg.time) cfg
    ), '[]'::jsonb);
end;
$$;
revoke all on function get_availability_range(text, date, date) from public;
grant execute on function get_availability_range(text, date, date) to anon, authenticated;

-- Disponibilità di una singola data (check rapido prima di prenotare).
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
              and b.status in ('confirmed', 'cancellation_requested')  -- allineato a book_slot
            group by b.time, b.slot_type
        ) agg
        cross join lateral resolve_slot_config(v_org, p_date, agg.time) cfg
    ), '[]'::jsonb);
end;
$$;
revoke all on function get_slot_availability(text, date) from public;
grant execute on function get_slot_availability(text, date) to anon, authenticated;
