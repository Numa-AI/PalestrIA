-- ─── Storico messaggi/notifiche admin ───────────────────────────────────
-- Traccia tutte le notifiche inviate: prenotazioni, annullamenti, proximity, broadcast

CREATE TABLE IF NOT EXISTS admin_messages (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    type        TEXT NOT NULL,           -- 'booking', 'cancellation', 'proximity', 'proximity_no_booking', 'new_client', 'broadcast'
    title       TEXT NOT NULL,
    body        TEXT NOT NULL DEFAULT '',
    client_name TEXT,
    date        DATE,
    time        TEXT,
    slot_type   TEXT,
    sent_count  INTEGER NOT NULL DEFAULT 0,
    extra       JSONB                    -- dati extra (es. recipients broadcast, with_bonus, with_mora)
);

ALTER TABLE admin_messages ENABLE ROW LEVEL SECURITY;

-- Solo admin può leggere
CREATE POLICY "admin_messages_select" ON admin_messages
    FOR SELECT TO authenticated USING (
        (auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'
    );

-- Le Edge Functions usano service_role, quindi non servono policy di insert
