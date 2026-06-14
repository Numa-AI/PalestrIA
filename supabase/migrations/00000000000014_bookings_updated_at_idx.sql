-- Indice per il delta-sync di BookingStorage (riduzione egress).
-- La query incrementale filtra .gte('updated_at', cursore) entro la finestra org/date;
-- questo indice composito (org_id, updated_at) evita lo scan completo della finestra.
-- Solo latenza, nessun impatto su egress. Coerente con gli altri bookings_org_*_idx della baseline.
create index if not exists bookings_org_updated_idx on bookings (org_id, updated_at);
