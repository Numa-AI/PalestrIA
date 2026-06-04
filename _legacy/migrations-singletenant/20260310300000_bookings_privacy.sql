-- ─── PRIVACY BOOKINGS + RPC DISPONIBILITÀ ────────────────────────────────────
-- Obiettivo: gli utenti non loggati non possono leggere i dati personali dei booking
-- (nome, email, telefono). Il calendario mostra comunque la disponibilità degli slot
-- tramite le RPC SECURITY DEFINER qui sotto.

-- ── RPC: get_slot_availability (singola data) ─────────────────────────────────
-- Usata per check rapido disponibilità slot (es. prima di prenotare).
create or replace function get_slot_availability(p_date date)
returns table(slot_time text, slot_type text, confirmed_count bigint)
language sql security definer stable as $$
    select "time", slot_type, count(*) as confirmed_count
    from   bookings
    where  "date" = p_date and status = 'confirmed'
    group  by "time", slot_type;
$$;

-- ── RPC: get_availability_range (range di date) ───────────────────────────────
-- Usata al caricamento pagina per precaricare la disponibilità (più efficiente di N chiamate).
create or replace function get_availability_range(p_start date, p_end date)
returns table(slot_date date, slot_time text, slot_type text, confirmed_count bigint)
language sql security definer stable as $$
    select "date", "time", slot_type, count(*) as confirmed_count
    from   bookings
    where  "date" between p_start and p_end and status = 'confirmed'
    group  by "date", "time", slot_type;
$$;

-- Entrambe accessibili a tutti (anon e authenticated) — restituiscono solo conteggi
grant execute on function get_slot_availability(date) to anon, authenticated;
grant execute on function get_availability_range(date, date) to anon, authenticated;

-- ── Aggiorna RLS bookings ─────────────────────────────────────────────────────
-- Rimuovi la policy che esponeva tutti i booking (nomi, email, telefoni) agli anonimi
drop policy if exists "bookings_public_read" on bookings;

-- Utenti autenticati vedono solo i propri booking (admin vede tutti tramite is_admin())
drop policy if exists "bookings_own_read" on bookings;
create policy "bookings_own_read"
    on bookings for select to authenticated
    using (user_id = auth.uid() or is_admin());

-- La policy di insert pubblica rimane invariata (prenotazioni anonime consentite)
-- "bookings_public_insert" è già presente — non toccare
